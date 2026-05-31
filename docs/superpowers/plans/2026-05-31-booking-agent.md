# Booking Agent + Google Calendar Connector (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Phase-2 **scheduling**: (1) a NEW Google Calendar connector package `Packages/SenaniCalendar` that mirrors the frozen `SenaniGmail` connector — a `CalendarClient` over the injected `HTTPClient` + `AccessTokenProviding`, exposing `freeBusy(range:)`, `listEvents(range:)`, and `proposeHold(...)` (which builds — but does NOT send — a tentative-event request); and (2) a `BookingAgent: SenaniEngine.Agent` co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/` that wakes for Booking-category messages (or messages asking to meet), reads availability through an injected calendar seam, picks **three** concrete non-conflicting slots from free/busy, and emits a single **outbound** `reply` Action proposing those slots. Because `Action.reply` is `ActionClass.outbound`, `ActionRouter.route` ALWAYS routes it to the approval queue — the agent never auto-sends and never auto-books. Fully unit-tested with a fake `HTTPClient` returning canned freeBusy/events JSON, a fake `TextGenerator`, and a fake calendar seam; no real Google network.

**Architecture:** Two pieces, both pure/testable:

1. **`SenaniCalendar`** (NEW SwiftPM library, sibling of `SenaniGmail` under `Packages/`). It mirrors `SenaniGmail`'s seams **exactly** so the live app can reuse the same OAuth machinery: it depends on `SenaniRules` only and re-declares the same `HTTPClient` / `AccessTokenProviding` protocol *shapes* the app already injects. To avoid a second, incompatible `HTTPClient`/`AccessTokenProviding` definition, `SenaniCalendar` **imports `SenaniGmail`** and reuses its `HTTPClient`, `AccessTokenProviding`, and `HTTPClientError` types directly (verified public in `SenaniGmail`). `SenaniCalendar` adds a `CalendarEndpoints` enum (request builders, mirroring `GmailEndpoints`), Codable response models, a `CalendarSlot`/`FreeBusyInterval`/`CalendarEvent` value types, and a `CalendarClient` struct (mirroring `GmailSync`) with `freeBusy(range:)`, `listEvents(range:)`, and `proposeHold(...)`. `proposeHold(...)` is a **request builder + draft model** only (returns a `TentativeHoldDraft` and the `URLRequest` that would create it) — it does NOT execute the insert, because **writing a real tentative hold to Google Calendar requires a `SenaniRules.Action` case that does not exist** (see §5 flag below). The OAuth **scope addition** (`calendar.readonly` + `calendar.events`) may force re-consent — flagged to the human (§5).

2. **`BookingAgent`** conforms to `SenaniEngine.Agent` (the §3 contract from [`2026-05-31-APP-PLANS-RECONCILIATION.md`](2026-05-31-APP-PLANS-RECONCILIATION.md)), **co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`** (matching the Triage / Reply-Drafter co-location decision). It stays **pure**: it never touches Google directly. Calendar availability reaches the agent through an injected **`AvailabilityProviding`** seam (an async protocol the agent holds), satisfied in production by a small adapter wrapping `SenaniCalendar.CalendarClient`, and in tests by a fake returning canned free/busy. `wakesFor(_:context:)` returns `true` for messages triaged into the **Booking** category (a `"Booking"` label on the message) **or** whose subject/body asks to meet (keyword heuristic). `proposals(for:context:tools:)` asks the seam for free/busy over a forward-looking window, computes the **first three** non-conflicting business-hours slots, renders them into a reply body (optionally polished by the injected `TextGenerator`), and returns `[tools.reply(to: message, body: ...)]`. `AgentTools.reply(to:body:)` maps to `SenaniRules.Action.reply(body:)`, whose `actionClass == .outbound`, so the Orchestrator's `ActionRouter.route` always yields `.queuedForApproval`. **No tentative hold is written in Phase 2** — that needs a new `Action` case and is flagged as a §5 blocking item.

**Tech Stack:** Swift 6.2 toolchain, `swift-tools-version: 6.0`, macOS 14, Apple Silicon, strict concurrency (complete), Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). `SenaniCalendar` path deps: `../SenaniRules`, `../SenaniGmail`. `SenaniEngine` (Booking agent) gains a path dep on `../SenaniCalendar` for the production `AvailabilityProviding` adapter only; the agent itself depends only on the seam. No MLX, no real Google network, no SwiftUI in either package — every test runs on local fakes. Google Calendar API: freeBusy at `POST https://www.googleapis.com/calendar/v3/freeBusy`; events at `GET/POST https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events`.

**Working directory:** Unless stated otherwise, `SenaniCalendar` tasks run `swift` commands from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar`; `BookingAgent` tasks run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine`.

**Design source / authority:** `docs/ARCHITECTURE.md` ("Booking agent", "Connectors: Gmail + Calendar, OAuth-scoped", the trust model — *Agents propose; you approve. Anything outbound is created as a draft/proposal, never auto-sent*), `docs/ROADMAP.md` Phase 2 ("Booking agent — calendar-aware scheduling"), and `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §2 (real `SenaniGmail` OAuth/HTTP signatures to MIRROR), §3 (`Agent`/`AgentContext`/`AgentTools` contract; `reply(to:body:)` → outbound `Action.reply`), §4 (conventions), §5 (a NEW `Action` case requires human sign-off; Calendar scope may require re-consent). It mirrors the patterns in `2026-05-31-gmail-oauth-and-onboarding.md` and `2026-05-31-agent-engine-orchestrator-and-scheduler.md`, and uses `2026-05-31-reply-drafter-agent.md` as the co-located-agent FORMAT exemplar.

**New-package vs module justification (Calendar):** A **new package `Packages/SenaniCalendar`** is correct (not a module inside `SenaniGmail` or `SenaniEngine`). Rationale: (a) it mirrors the existing one-connector-per-package layout (`SenaniGmail` is its own package); (b) it must be injectable into the app's composition root exactly like `SenaniGmail`, with the same `HTTPClient`/`AccessTokenProviding` seams, so it belongs at the connectors tier, not the engine/agent tier; (c) keeping it out of `SenaniEngine` preserves the rule that **`SenaniEngine` depends only on frozen engine packages + connectors via seams** — the Booking agent codes against an `AvailabilityProviding` seam, and only a thin production adapter (not the agent) references `SenaniCalendar`. It reuses `SenaniGmail`'s `HTTPClient`/`AccessTokenProviding`/`OAuthToken`/`GmailAuth` rather than re-declaring them, so the same Keychain-backed token (with the added Calendar scope) drives both connectors.

**Out of scope (separate plans):**
- The live OAuth re-consent flow + adding the Calendar scopes to the consent URL (owned by the Gmail-OAuth/onboarding plan; this plan only documents the scope strings and flags the re-consent requirement — §5).
- The app-shell composition root wiring (`AppEnvironment` constructing `CalendarClient` + the `AvailabilityProviding` adapter and registering `BookingAgent` in the `AgentRegistry`) — owned by the app-shell plan; this plan documents the one-line registration + adapter so that plan can wire it.
- Executing an approved reply into Gmail as a DRAFT/send (`GmailMailBackend`, owned by the Approval-queue UI plan).
- **Auto-creating a tentative calendar hold on approval** — requires a new `SenaniRules.Action` case (`.calendarHold(...)`) that the frozen package lacks → flagged as a §5 blocking item for a later iteration (see "Deferred: real calendar hold" below). This plan ships only the *request builder* (`proposeHold`) and does NOT route a hold action.

---

## Cross-package assumptions (verified from source on 2026-05-31 — state to the human before coding)

### `SenaniEngine` dependency — co-location decision (FLAG TO HUMAN)
`Packages/SenaniEngine` is a NEW app-tier package owning `Agent`, `AgentContext`, `AgentTools`, `AgentRegistry`, `Orchestrator`, `Scheduler` (§3). It is scaffolded by the orchestrator plan (`2026-05-31-agent-engine-orchestrator-and-scheduler.md`) and the Triage/Reply-Drafter plans. The **Booking agent is co-located inside `SenaniEngine`** (same package as the protocol + the other agents). At build time:

- **If `SenaniEngine` already exists** (orchestrator/Triage/Reply-Drafter landed first): do NOT recreate the package or redefine `Agent`/`AgentContext`/`AgentTools`. Verify the on-disk `Agent`/`AgentContext`/`AgentTools` match the §3 signatures pinned below; if they differ, adapt `BookingAgent` to the real ones and record the deviation in the commit body. Add only the `Agents/BookingAgent.swift` + `AvailabilityProviding.swift` + production adapter + tests, and add the `../SenaniCalendar` path dep to `SenaniEngine/Package.swift`.
- **If `SenaniEngine` does not exist yet:** this plan does NOT scaffold it (that is the orchestrator plan's job and a shared-file coordination point). STOP and report that `SenaniEngine` must be built first (it is the critical-path dependency). Do not fork the engine contract.

This is a **shared-package coordination point** — flag it so two plans do not both edit `SenaniEngine/Package.swift` or redefine the contract.

### `SenaniGmail` (built + frozen — MIRRORED and REUSED, do NOT edit — verified)
Read from `Packages/SenaniGmail/Sources/SenaniGmail/**`:
```swift
// HTTPClient.swift
public enum HTTPClientError: Error, Equatable { case noQueuedResponse; case nonHTTPResponse; case unexpectedStatus(Int, body: String) }
public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
public struct URLSessionHTTPClient: HTTPClient { public init(session: URLSession = .shared) }

// GmailAuth.swift
public protocol AccessTokenProviding: Sendable { func validAccessToken() async throws -> String }
public actor GmailAuth: AccessTokenProviding {
    public init(clientID: String, http: any HTTPClient, store: any TokenStore, now: @escaping @Sendable () -> Date = Date.init)
    public static func authorizationURL(clientID: String, redirectURI: String, scopes: [String], pkce: PKCE, state: String) -> URL
    public func validAccessToken() async throws -> String
    static func validate(response: HTTPURLResponse, data: Data) throws   // ⚠ INTERNAL — not usable from SenaniCalendar
}

// Keychain.swift
public struct OAuthToken: Sendable, Equatable, Codable { public var accessToken: String; public var refreshToken: String; public var expiresAt: Date }
public protocol TokenStore: Sendable { func load() async throws -> OAuthToken?; func save(_:) async throws; func clear() async throws }
public actor InMemoryTokenStore: TokenStore { public init() }            // tests
public struct KeychainTokenStore: TokenStore { public init(service:account:) }   // live
```
**Pinned consequences for `SenaniCalendar`:**
- `SenaniCalendar` **reuses** `SenaniGmail.HTTPClient`, `SenaniGmail.AccessTokenProviding`, `SenaniGmail.HTTPClientError`, and (in the app) the same `GmailAuth` token provider — it does NOT redefine them. This guarantees one token, one OAuth flow drives both connectors.
- `GmailAuth.validate(response:data:)` is **internal** to `SenaniGmail`, so `SenaniCalendar` cannot call it. `SenaniCalendar` defines its **own** tiny `CalendarHTTP.validate(response:data:)` that throws `SenaniGmail.HTTPClientError.unexpectedStatus(_:body:)` on `statusCode >= 300` — mirroring the pattern without depending on the internal symbol. (Verified: `HTTPClientError` is public; `GmailAuth.validate` is not marked `public`.)
- `authorizationURL(...)` takes a `scopes: [String]` array — the live onboarding plan appends the Calendar scopes. This plan only declares the scope constants (`CalendarScopes`) and flags re-consent.

### `SenaniRules` (built + frozen, do NOT edit — verified)
```swift
public struct Message: Sendable, Equatable, Identifiable {
    public init(id:from:to:subject:body:hasAttachment:listUnsubscribeHeader:labels:threadId:date:isFromUser:)
    // id, from:String, to:[String], subject, body, hasAttachment, listUnsubscribeHeader:String?,
    // labels:[String], threadId, date:Date, isFromUser:Bool ; computed var senderDomain: String
}
public enum Action: Sendable, Equatable {
    case label(String); case archive; case markRead; case markUnread; case star; case unstar
    case move(String); case flagNeedsReply; case fileAttachment(folder:); case parseDoc
    case runAgent(id:); case draft(body:); case reply(body:); case forward(to:body:); case send(body:)
    case markSpam; case localWebhook(name:)
}                                                       // ⚠ NO calendar/hold case exists
public enum ActionClass: Sendable, Equatable { case reversible; case outbound }
extension Action { public var actionClass: ActionClass }  // .reply/.forward/.send/.markSpam => .outbound ; else .reversible
public enum ActionRouter { public static func route(_ action: Action, autonomy: Autonomy) -> Outcome }
// VERIFIED first line of route(): `if action.actionClass == .outbound { return .queuedForApproval }`
public enum Autonomy: String, Sendable, Equatable { case ask; case prepare; case auto }
public enum Outcome: Sendable, Equatable { case executed; case prepared; case queuedForApproval }
```
> **`reply` → which `Action` case (reconciliation).** §3 declares `AgentTools.reply(to:body:) -> Action` mapping to `SenaniRules.Action.reply(body:)`. Its `actionClass == .outbound`, so `ActionRouter.route` ALWAYS yields `.queuedForApproval` regardless of the agent's autonomy. This is exactly the trust-model guarantee for Booking: the agent **proposes** slots; a human approves the outgoing email. This plan does NOT add a new `Action` case.
>
> **Deferred: real calendar hold (§5 blocking).** Writing a tentative hold to Google Calendar would need an outbound `SenaniRules.Action` case the frozen enum lacks (e.g. `.calendarHold(calendarId:title:start:end:)`). Per §5, that is a **blocking change to a frozen package** requiring human sign-off (extend + re-freeze `SenaniRules.Action`, then add a `proposeHold` tool + Orchestrator routing + `CalendarMailBackend`-style executor). This plan deliberately does NOT fork the action model: `CalendarClient.proposeHold(...)` builds the request + draft object for that future iteration but is never routed as an Action. Flagged for the human (§5; see Self-Review).

### `SenaniEngine` §3 contract this plan PINS (verified shape from the reconciliation + reply-drafter plan)
```swift
public protocol Agent: Sendable {
    var id: String { get }
    var autonomy: Autonomy { get }
    func wakesFor(_ message: Message, context: AgentContext) -> Bool
    func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action]
}
public struct AgentContext: Sendable {
    public let account: String
    public let thread: [Message]
    public let rules: [Rule]
    public let retrieve: @Sendable (_ query: String, _ k: Int) async throws -> [VectorHit]
    public let now: Date
    // NOTE: the Reply-Drafter plan adds an additive `needsReply: Bool = false`. Booking does NOT
    // require any new AgentContext field — it reads availability through its injected seam and uses
    // `context.now` for the search window + `message.labels`/subject/body for the trigger. If the
    // on-disk AgentContext has extra defaulted fields, that is fine; Booking ignores them.
}
public struct AgentTools: Sendable {
    public func reply(to message: Message, body: String) -> Action            // ⇒ .reply(body:) (outbound)
    public func proposeLabel(_ label: String, on message: Message) -> Action
    public func archive(_ message: Message) -> Action
    public func markRead(_ message: Message) -> Action
}
```
> ⚠ **Tool method name check.** The reconciliation §3 names the outbound builder `reply(to:body:)`; the Reply-Drafter plan named it `draftReply(to:body:)`. **Both map to `Action.reply(body:)`.** Before writing `BookingAgent`, inspect the on-disk `AgentTools` and call whichever builder exists that returns `.reply(body:)`. If only `draftReply` exists, use it; if `reply` exists, use it. Task 9 includes a one-line verification step. If neither exists (only `proposeLabel`/`archive`/`markRead`), BookingAgent constructs `Action.reply(body:)` directly via the (re-exported) `SenaniRules` enum and records the deviation — the outbound guarantee is preserved either way because `ActionRouter` keys off `actionClass`, not the builder.

### Key consequences pinned for the implementer
- `CalendarClient` is `async throws` (mirrors `GmailSync`); the `AvailabilityProviding` seam is `async throws`. `wakesFor` is pure/sync. `proposals` is `async throws` (it awaits the seam + optional generator).
- The Booking agent is **pure** (§4): its only I/O is the injected `AvailabilityProviding` seam and the optional injected `TextGenerator`. It never reads stores, never builds `URLRequest`s, never touches Google.
- Slot selection is **deterministic** given (now, freeBusy, config) so it is unit-testable without a clock or network. Times are computed in a fixed `TimeZone` injected into the agent (default the user's current zone; tests inject a fixed zone) so assertions are stable.

---

## File Structure

```
Packages/SenaniCalendar/
  Package.swift
  Sources/SenaniCalendar/
    CalendarScopes.swift        # the OAuth scope strings (calendar.readonly + calendar.events)
    CalendarModels.swift        # CalendarSlot, FreeBusyInterval, CalendarEvent, TentativeHoldDraft, DateRange
    CalendarEndpoints.swift     # request builders (freeBusy / listEvents / insertTentativeEvent) + Codable DTOs
    CalendarHTTP.swift          # validate(response:data:) mirror (throws SenaniGmail.HTTPClientError)
    CalendarClient.swift        # struct CalendarClient: freeBusy / listEvents / proposeHold (over HTTPClient + AccessTokenProviding)
  Tests/SenaniCalendarTests/
    CalendarFixtures.swift              # canned freeBusy / events JSON + a FakeHTTPClient + StubTokenProvider
    CalendarEndpointsTests.swift        # request builders produce the expected URL/method/auth/body
    CalendarClientTests.swift           # client parses freeBusy/events, proposeHold builds (but does not send) the insert

Packages/SenaniEngine/                  # EXISTING package (scaffolded by the orchestrator plan)
  Package.swift                         # ADD: .package(path: "../SenaniCalendar") + product dep (Task 5)
  Sources/SenaniEngine/
    AvailabilityProviding.swift         # seam + SenaniCalendar production adapter
    Agents/
      BookingAgent.swift                # the agent (wakesFor + proposals + pure slot selection)
  Tests/SenaniEngineTests/
    Booking/
      BookingFixtures.swift             # Message/context builders + canned availability
      FakeAvailabilityProvider.swift    # recording fake returning canned free/busy
      RecordingTextGenerator.swift      # local fake TextGenerator (only if not already present from Reply-Drafter)
      BookingWakesForTests.swift        # wakes for Booking-category / meeting-intent; not otherwise
      BookingSlotSelectionTests.swift   # pure slot picker: 3 non-conflicting business-hours slots
      BookingProposalsTests.swift       # emits ONE outbound .reply proposing 3 slots; no network
```

Each file has one responsibility. `SenaniCalendar`'s only product is the `SenaniCalendar` library; its test target reuses `CalendarFixtures.swift`. The Booking additions reuse the existing `SenaniEngineTests` target.

---

## Task 1 — `SenaniCalendar` package scaffold + path deps

**Files:**
- Create: `Packages/SenaniCalendar/Package.swift`
- Create: `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarScopes.swift`
- Test: `Packages/SenaniCalendar/Tests/SenaniCalendarTests/ScopesProbeTests.swift`

- [ ] **Step 1: Write a failing import + scope test**

Create `Packages/SenaniCalendar/Tests/SenaniCalendarTests/ScopesProbeTests.swift`:

```swift
import Testing
@testable import SenaniCalendar
import SenaniGmail
import SenaniRules

@Test func packageLinksGmailSeamsAndDeclaresCalendarScopes() {
    // Proves the package builds, links SenaniGmail (HTTPClient seam) + SenaniRules.
    let _: any HTTPClient.Type = URLSessionHTTPClient.self
    let action: SenaniRules.Action = .reply(body: "x")
    #expect(action.actionClass == .outbound)
    #expect(CalendarScopes.all.contains("https://www.googleapis.com/auth/calendar.readonly"))
    #expect(CalendarScopes.all.contains("https://www.googleapis.com/auth/calendar.events"))
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test
```

Expected: failure — no `Package.swift` / `error: no such module 'SenaniCalendar'`.

- [ ] **Step 3: Create the manifest with path deps**

Create `Packages/SenaniCalendar/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniCalendar", targets: ["SenaniCalendar"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniGmail"),
    ],
    targets: [
        .target(
            name: "SenaniCalendar",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniGmail", package: "SenaniGmail"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniCalendarTests",
            dependencies: ["SenaniCalendar"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

Create `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarScopes.swift`:

```swift
/// Google Calendar OAuth scopes the Booking connector requests.
///
/// ⚠ Adding these to the existing Gmail consent URL CHANGES the granted scope set and will
/// force the user to RE-CONSENT (Google re-prompts when scopes expand). The live onboarding
/// plan owns appending these to `GmailAuth.authorizationURL(scopes:)`. Flagged in §5.
public enum CalendarScopes {
    /// Read free/busy + events.
    public static let readonly = "https://www.googleapis.com/auth/calendar.readonly"
    /// Create/modify events (needed only for a future tentative-hold write — see the §5 deferral).
    public static let events = "https://www.googleapis.com/auth/calendar.events"

    /// Both scopes, in the order appended to the consent URL.
    public static let all: [String] = [readonly, events]
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test
```

Expected: 1 test passes (`packageLinksGmailSeamsAndDeclaresCalendarScopes`).

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniCalendar: package scaffold (SenaniRules + SenaniGmail path deps) + Calendar OAuth scopes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

Use this commit trailer on EVERY commit in this plan.

---

## Task 2 — Calendar value types (models)

**Files:**
- Create: `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarModels.swift`
- Test: `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarModelsTests.swift`

The connector exposes plain value types so callers never touch Google JSON. `DateRange` bounds a query window; `FreeBusyInterval` is one busy block; `CalendarEvent` is a listed event; `CalendarSlot` is a proposed free slot; `TentativeHoldDraft` is the *draft* a future hold-write would use (built by `proposeHold`, never sent in Phase 2).

- [ ] **Step 1: Write a failing models test**

Create `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarModelsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniCalendar

@Test func dateRangeAndIntervalsAreValueTypes() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(3_600)
    let range = DateRange(start: start, end: end)
    #expect(range.start == start)
    #expect(range.end == end)

    let busy = FreeBusyInterval(start: start, end: end)
    #expect(busy == FreeBusyInterval(start: start, end: end))

    let slot = CalendarSlot(start: start, end: end)
    #expect(slot.duration == 3_600)

    let event = CalendarEvent(id: "e1", title: "Sync", start: start, end: end)
    #expect(event.title == "Sync")

    let draft = TentativeHoldDraft(calendarId: "primary", title: "Hold: Sarah", start: start, end: end)
    #expect(draft.calendarId == "primary")
    #expect(draft.title == "Hold: Sarah")
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test --filter CalendarModelsTests
```

Expected: failure — `DateRange`/`FreeBusyInterval`/`CalendarSlot`/`CalendarEvent`/`TentativeHoldDraft` undefined.

- [ ] **Step 3: Implement the models**

Create `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarModels.swift`:

```swift
import Foundation

/// A half-open query window [start, end).
public struct DateRange: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// One busy block returned by the freeBusy API.
public struct FreeBusyInterval: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// A listed calendar event (from events.list).
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public init(id: String, title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

/// A proposed free slot the Booking agent can offer.
public struct CalendarSlot: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A DRAFT for a tentative hold. Built by `CalendarClient.proposeHold(...)` but NEVER inserted
/// in Phase 2 (writing it needs a new SenaniRules.Action case — §5). It carries everything a
/// future hold-write would need.
public struct TentativeHoldDraft: Sendable, Equatable {
    public let calendarId: String
    public let title: String
    public let start: Date
    public let end: Date
    public init(calendarId: String, title: String, start: Date, end: Date) {
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test --filter CalendarModelsTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniCalendar: value types (DateRange/FreeBusyInterval/CalendarEvent/CalendarSlot/TentativeHoldDraft)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — `CalendarEndpoints` request builders (+ DTOs) and `CalendarHTTP.validate`

**Files:**
- Create: `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarEndpoints.swift`
- Create: `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarHTTP.swift`
- Create: `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarEndpointsTests.swift`

Mirror `GmailEndpoints`: an enum of static request builders that set the `Authorization: Bearer` header, the method, and a JSON body (for POST). RFC 3339 timestamps in UTC (`yyyy-MM-dd'T'HH:mm:ss'Z'`) for the freeBusy/insert bodies. `CalendarHTTP.validate` mirrors `GmailAuth.validate` (which is internal) by throwing `SenaniGmail.HTTPClientError.unexpectedStatus` on non-2xx.

- [ ] **Step 1: Write failing endpoint tests**

Create `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarEndpointsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniCalendar
import SenaniGmail

@Test func freeBusyRequestIsAuthorizedPostWithTimeWindow() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
    let end = start.addingTimeInterval(7 * 86_400)
    let req = CalendarEndpoints.freeBusy(
        range: DateRange(start: start, end: end),
        calendarIds: ["primary"],
        accessToken: "TOKEN"
    )
    #expect(req.url?.absoluteString == "https://www.googleapis.com/calendar/v3/freeBusy")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
    #expect(body?["timeMin"] as? String == "2023-11-14T22:13:20Z")
    let items = body?["items"] as? [[String: Any]]
    #expect(items?.first?["id"] as? String == "primary")
}

@Test func listEventsRequestIsAuthorizedGetWithSingleEventsExpansion() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(7 * 86_400)
    let req = CalendarEndpoints.listEvents(
        range: DateRange(start: start, end: end),
        calendarId: "primary",
        accessToken: "T"
    )
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.path == "/calendar/v3/calendars/primary/events")
    #expect(req.httpMethod == "GET")
    let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(q["timeMin"] == "2023-11-14T22:13:20Z")
    #expect(q["singleEvents"] == "true")
    #expect(q["orderBy"] == "startTime")
}

@Test func insertTentativeEventRequestBuildsTransparentTentativeBody() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(1_800)
    let draft = TentativeHoldDraft(calendarId: "primary", title: "Hold: Sarah", start: start, end: end)
    let req = CalendarEndpoints.insertTentativeEvent(draft: draft, accessToken: "T")
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.path == "/calendar/v3/calendars/primary/events")
    #expect(req.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
    #expect(body?["status"] as? String == "tentative")
    #expect(body?["summary"] as? String == "Hold: Sarah")
    let startObj = body?["start"] as? [String: Any]
    #expect(startObj?["dateTime"] as? String == "2023-11-14T22:13:20Z")
}

@Test func validateThrowsGmailHTTPStatusErrorOnNon2xx() {
    let url = URL(string: "https://www.googleapis.com/calendar/v3/freeBusy")!
    let bad = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
    #expect(throws: HTTPClientError.self) {
        try CalendarHTTP.validate(response: bad, data: Data(#"{"error":"denied"}"#.utf8))
    }
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    #expect(throws: Never.self) { try CalendarHTTP.validate(response: ok, data: Data()) }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test --filter CalendarEndpointsTests
```

Expected: failure — `CalendarEndpoints` / `CalendarHTTP` undefined.

- [ ] **Step 3: Implement endpoints + DTOs + validate**

Create `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarHTTP.swift`:

```swift
import Foundation
import SenaniGmail

/// HTTP helpers mirroring SenaniGmail's pattern. `GmailAuth.validate(response:data:)` is internal
/// to SenaniGmail, so we re-implement the same check here, reusing the PUBLIC `HTTPClientError`.
public enum CalendarHTTP {
    public static func validate(response: HTTPURLResponse, data: Data) throws {
        guard response.statusCode < 300 else {
            throw HTTPClientError.unexpectedStatus(
                response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }

    /// RFC 3339 in UTC, e.g. "2023-11-14T22:13:20Z" — the format Calendar's timeMin/timeMax expect.
    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func timestamp(_ date: Date) -> String { rfc3339.string(from: date) }
    public static func date(from string: String) -> Date? { rfc3339.date(from: string) }
}
```

Create `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarEndpoints.swift`:

```swift
import Foundation

/// Request builders for the Google Calendar v3 API, mirroring `SenaniGmail.GmailEndpoints`.
/// Pure: each returns a `URLRequest` with the Bearer header set; none performs I/O.
public enum CalendarEndpoints {
    static let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!

    /// POST /freeBusy — busy intervals for the given calendars over [start, end).
    public static func freeBusy(
        range: DateRange,
        calendarIds: [String],
        accessToken: String
    ) -> URLRequest {
        var request = authorizedRequest(url: baseURL.appendingPathComponent("freeBusy"),
                                        method: "POST", accessToken: accessToken)
        setJSONBody([
            "timeMin": CalendarHTTP.timestamp(range.start),
            "timeMax": CalendarHTTP.timestamp(range.end),
            "items": calendarIds.map { ["id": $0] },
        ], on: &request)
        return request
    }

    /// GET /calendars/{id}/events — single (expanded) events over [start, end), ordered by start.
    public static func listEvents(
        range: DateRange,
        calendarId: String,
        accessToken: String
    ) -> URLRequest {
        let path = "calendars/\(calendarId)/events"
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "timeMin", value: CalendarHTTP.timestamp(range.start)),
            URLQueryItem(name: "timeMax", value: CalendarHTTP.timestamp(range.end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
        ]
        return authorizedRequest(url: comps.url!, method: "GET", accessToken: accessToken)
    }

    /// POST /calendars/{id}/events — builds (does NOT send) a tentative hold insert.
    /// Used only by `CalendarClient.proposeHold` for a FUTURE iteration (§5); not routed in Phase 2.
    public static func insertTentativeEvent(
        draft: TentativeHoldDraft,
        accessToken: String
    ) -> URLRequest {
        let path = "calendars/\(draft.calendarId)/events"
        var request = authorizedRequest(url: baseURL.appendingPathComponent(path),
                                        method: "POST", accessToken: accessToken)
        setJSONBody([
            "summary": draft.title,
            "status": "tentative",
            "transparency": "opaque",
            "start": ["dateTime": CalendarHTTP.timestamp(draft.start)],
            "end": ["dateTime": CalendarHTTP.timestamp(draft.end)],
        ], on: &request)
        return request
    }

    private static func authorizedRequest(url: URL, method: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func setJSONBody(_ object: Any, on request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - Response DTOs (decoded inside CalendarClient)

struct FreeBusyResponse: Decodable {
    var calendars: [String: FreeBusyCalendar]?
}

struct FreeBusyCalendar: Decodable {
    var busy: [FreeBusyBusy]?
}

struct FreeBusyBusy: Decodable {
    var start: String
    var end: String
}

struct EventsListResponse: Decodable {
    var items: [EventItem]?
}

struct EventItem: Decodable {
    var id: String?
    var summary: String?
    var start: EventDateTime?
    var end: EventDateTime?
}

struct EventDateTime: Decodable {
    var dateTime: String?
    var date: String?   // all-day events use `date` instead of `dateTime`
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test --filter CalendarEndpointsTests
```

Expected: all 4 pass. (If the RFC-3339 string differs by a colon/`+00:00` vs `Z`, adjust the formatter to `[.withInternetDateTime]` with a UTC zone so it emits trailing `Z` — the tests pin `Z`.)

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniCalendar: CalendarEndpoints request builders + DTOs + CalendarHTTP.validate (mirrors GmailEndpoints)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — `CalendarClient` (freeBusy / listEvents / proposeHold)

**Files:**
- Create: `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarClient.swift`
- Create: `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarFixtures.swift`
- Create: `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarClientTests.swift`

`CalendarClient` mirrors `GmailSync`: holds an `HTTPClient` + `AccessTokenProviding`, fetches a token, sends the request, validates, decodes. `freeBusy` returns `[FreeBusyInterval]`; `listEvents` returns `[CalendarEvent]`; `proposeHold(slot:title:calendarId:)` returns a `TentativeHoldDraft` AND the `URLRequest` that *would* create it — but **does not send it** (Phase 2 has no Action to route it through). Tests use a local `FakeHTTPClient` (mirroring `SenaniGmail`'s test double) returning canned JSON.

- [ ] **Step 1: Write fixtures + failing client tests**

Create `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarFixtures.swift`:

```swift
import Foundation
@testable import SenaniCalendar
import SenaniGmail

/// Local HTTP fake mirroring SenaniGmail's FakeHTTPClient (SenaniGmail ships no public fakes).
actor FakeHTTPClient: HTTPClient {
    struct Queued { let data: Data; let response: HTTPURLResponse }
    private var queue: [Queued] = []
    private(set) var recordedRequests: [URLRequest] = []

    func enqueueJSON(_ json: String, status: Int = 200,
                     url: URL = URL(string: "https://www.googleapis.com/calendar/v3")!) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        queue.append(Queued(data: Data(json.utf8), response: response))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queue.isEmpty else { throw HTTPClientError.noQueuedResponse }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }
}

struct StubTokenProvider: AccessTokenProviding {
    let token: String
    func validAccessToken() async throws -> String { token }
}

enum CalFix {
    /// Two busy blocks on the primary calendar.
    static let freeBusyJSON = """
    {"calendars":{"primary":{"busy":[
      {"start":"2023-11-15T09:00:00Z","end":"2023-11-15T10:00:00Z"},
      {"start":"2023-11-15T13:00:00Z","end":"2023-11-15T14:00:00Z"}
    ]}}}
    """

    /// One timed event + one all-day event (all-day uses `date`, no `dateTime`).
    static let eventsJSON = """
    {"items":[
      {"id":"e1","summary":"Standup","start":{"dateTime":"2023-11-15T09:00:00Z"},"end":{"dateTime":"2023-11-15T09:30:00Z"}},
      {"id":"e2","summary":"Holiday","start":{"date":"2023-11-16"},"end":{"date":"2023-11-17"}}
    ]}
    """
}
```

Create `Packages/SenaniCalendar/Tests/SenaniCalendarTests/CalendarClientTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniCalendar
import SenaniGmail

private func range() -> DateRange {
    let start = CalendarHTTP.date(from: "2023-11-15T00:00:00Z")!
    return DateRange(start: start, end: start.addingTimeInterval(7 * 86_400))
}

@Test func freeBusyParsesBusyIntervals() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.freeBusyJSON)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))

    let busy = try await client.freeBusy(range: range())

    #expect(busy.count == 2)
    #expect(busy.first?.start == CalendarHTTP.date(from: "2023-11-15T09:00:00Z"))
    #expect(busy.first?.end == CalendarHTTP.date(from: "2023-11-15T10:00:00Z"))
    // The request carried the Bearer token.
    let sent = await http.recordedRequests
    #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer T")
}

@Test func listEventsParsesTimedEventsAndSkipsAllDayWithoutDateTime() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(CalFix.eventsJSON)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))

    let events = try await client.listEvents(range: range())

    // The all-day event (no dateTime) is dropped; only the timed event remains.
    #expect(events.map(\.id) == ["e1"])
    #expect(events.first?.title == "Standup")
}

@Test func freeBusyThrowsOnHTTPError() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(#"{"error":"forbidden"}"#, status: 403)
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    await #expect(throws: HTTPClientError.self) {
        _ = try await client.freeBusy(range: range())
    }
}

@Test func proposeHoldBuildsDraftAndRequestButDoesNotSend() async throws {
    let http = FakeHTTPClient()   // nothing enqueued — proving no request is sent
    let client = CalendarClient(http: http, tokenProvider: StubTokenProvider(token: "T"))
    let start = CalendarHTTP.date(from: "2023-11-15T11:00:00Z")!
    let slot = CalendarSlot(start: start, end: start.addingTimeInterval(1_800))

    let (draft, request) = try await client.proposeHold(slot: slot, title: "Hold: Sarah", calendarId: "primary")

    #expect(draft.title == "Hold: Sarah")
    #expect(draft.start == start)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T")
    // CRITICAL: proposeHold NEVER hits the network in Phase 2.
    #expect(await http.recordedRequests.isEmpty)
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test --filter CalendarClientTests
```

Expected: failure — `CalendarClient` undefined.

- [ ] **Step 3: Implement `CalendarClient`**

Create `Packages/SenaniCalendar/Sources/SenaniCalendar/CalendarClient.swift`:

```swift
import Foundation
import SenaniGmail

/// The Google Calendar connector, mirroring `SenaniGmail.GmailSync`: it runs over the injected
/// `HTTPClient` + `AccessTokenProviding` (reused from SenaniGmail), so the same OAuth token (with
/// the added Calendar scope) drives both connectors. Pure transport + decode; no business logic.
public struct CalendarClient: Sendable {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding
    private let calendarId: String

    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding, calendarId: String = "primary") {
        self.http = http
        self.tokenProvider = tokenProvider
        self.calendarId = calendarId
    }

    /// Busy intervals over the window (across the configured calendar).
    public func freeBusy(range: DateRange) async throws -> [FreeBusyInterval] {
        let token = try await tokenProvider.validAccessToken()
        let request = CalendarEndpoints.freeBusy(range: range, calendarIds: [calendarId], accessToken: token)
        let (data, response) = try await http.send(request)
        try CalendarHTTP.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(FreeBusyResponse.self, from: data)
        let busy = decoded.calendars?[calendarId]?.busy ?? []
        return busy.compactMap { block in
            guard let start = CalendarHTTP.date(from: block.start),
                  let end = CalendarHTTP.date(from: block.end) else { return nil }
            return FreeBusyInterval(start: start, end: end)
        }
    }

    /// Timed events over the window. All-day events (no `dateTime`) are skipped.
    public func listEvents(range: DateRange) async throws -> [CalendarEvent] {
        let token = try await tokenProvider.validAccessToken()
        let request = CalendarEndpoints.listEvents(range: range, calendarId: calendarId, accessToken: token)
        let (data, response) = try await http.send(request)
        try CalendarHTTP.validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(EventsListResponse.self, from: data)
        return (decoded.items ?? []).compactMap { item in
            guard let id = item.id,
                  let startString = item.start?.dateTime,
                  let endString = item.end?.dateTime,
                  let start = CalendarHTTP.date(from: startString),
                  let end = CalendarHTTP.date(from: endString) else { return nil }
            return CalendarEvent(id: id, title: item.summary ?? "", start: start, end: end)
        }
    }

    /// Builds a tentative-hold draft AND the `URLRequest` that WOULD create it — but does NOT send it.
    /// Phase 2 has no SenaniRules.Action to route a hold through (§5), so the actual insert is deferred.
    /// Returned for a future iteration once a `.calendarHold` Action is added with human sign-off.
    public func proposeHold(
        slot: CalendarSlot,
        title: String,
        calendarId overrideCalendarId: String? = nil
    ) async throws -> (draft: TentativeHoldDraft, request: URLRequest) {
        let token = try await tokenProvider.validAccessToken()
        let cal = overrideCalendarId ?? calendarId
        let draft = TentativeHoldDraft(calendarId: cal, title: title, start: slot.start, end: slot.end)
        let request = CalendarEndpoints.insertTentativeEvent(draft: draft, accessToken: token)
        return (draft, request)   // ⚠ intentionally not sent — see §5 deferral
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test --filter CalendarClientTests
```

Expected: all 4 pass.

- [ ] **Step 5: Run the full SenaniCalendar suite + commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test
```

Expected: all suites green (`ScopesProbeTests`, `CalendarModelsTests`, `CalendarEndpointsTests`, `CalendarClientTests`).

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniCalendar: CalendarClient freeBusy/listEvents/proposeHold (proposeHold builds but never sends)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — Wire `SenaniCalendar` into `SenaniEngine` + the `AvailabilityProviding` seam

**Files:**
- Edit: `Packages/SenaniEngine/Package.swift` (add the `../SenaniCalendar` path dep + product dep)
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/AvailabilityProviding.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/FakeAvailabilityProvider.swift`

The Booking agent must stay pure (§4): it never holds a `CalendarClient`, builds a `URLRequest`, or imports `SenaniGmail`. It depends only on an async **`AvailabilityProviding`** seam. The production adapter (in `SenaniEngine`, wrapping `SenaniCalendar.CalendarClient`) is the *only* `SenaniEngine` code that imports `SenaniCalendar`.

- [ ] **Step 0: Confirm `SenaniEngine` exists**

```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine/Package.swift 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `ABSENT`:** STOP — `SenaniEngine` is the critical-path dependency (orchestrator plan). Report and do not scaffold it here.
- **If `EXISTS`:** continue.

- [ ] **Step 1: Add the SenaniCalendar dependency to `SenaniEngine/Package.swift`**

In `Packages/SenaniEngine/Package.swift`, add to the `dependencies:` array:
```swift
        .package(path: "../SenaniCalendar"),
```
and to the `SenaniEngine` target's `dependencies:`:
```swift
                .product(name: "SenaniCalendar", package: "SenaniCalendar"),
```
Leave all existing deps intact. (If the manifest uses `swiftLanguageModes: [.v6]` or per-target `swiftSettings`, do not change them.)

- [ ] **Step 2: Write a failing seam + adapter test**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/FakeAvailabilityProvider.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniCalendar
import SenaniGmail

/// Recording fake: returns canned busy intervals and records the query window it was asked.
final class FakeAvailabilityProvider: AvailabilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let busy: [FreeBusyInterval]
    private var windows: [DateRange] = []

    init(busy: [FreeBusyInterval]) { self.busy = busy }

    func busyIntervals(in range: DateRange) async throws -> [FreeBusyInterval] {
        lock.lock(); defer { lock.unlock() }
        windows.append(range)
        return busy
    }

    var recordedWindows: [DateRange] { lock.lock(); defer { lock.unlock() }; return windows }
}

@Suite struct AvailabilityProvidingTests {
    @Test func fakeReturnsCannedBusyAndRecordsWindow() async throws {
        let start = CalendarHTTP.date(from: "2023-11-15T09:00:00Z")!
        let busy = [FreeBusyInterval(start: start, end: start.addingTimeInterval(3_600))]
        let fake = FakeAvailabilityProvider(busy: busy)
        let window = DateRange(start: start, end: start.addingTimeInterval(86_400))
        let out = try await fake.busyIntervals(in: window)
        #expect(out == busy)
        #expect(fake.recordedWindows.count == 1)
    }

    @Test func calendarClientAdapterConformsAndForwardsToFreeBusy() async throws {
        // Compile + behavior guarantee that the production adapter wraps the real CalendarClient.
        let http = FakeCalHTTP()
        await http.enqueueFreeBusy()
        let client = CalendarClient(http: http, tokenProvider: StubCalToken(token: "T"))
        let adapter = CalendarAvailabilityProvider(client: client)
        let start = CalendarHTTP.date(from: "2023-11-15T00:00:00Z")!
        let out = try await adapter.busyIntervals(in: DateRange(start: start, end: start.addingTimeInterval(86_400)))
        #expect(out.count == 1)
    }
}

/// Minimal local fakes (SenaniGmail/SenaniCalendar ship no public fakes for the engine test target).
actor FakeCalHTTP: HTTPClient {
    private var queue: [(Data, HTTPURLResponse)] = []
    func enqueueFreeBusy() {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/freeBusy")!
        let json = #"{"calendars":{"primary":{"busy":[{"start":"2023-11-15T09:00:00Z","end":"2023-11-15T10:00:00Z"}]}}}"#
        queue.append((Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !queue.isEmpty else { throw HTTPClientError.noQueuedResponse }
        return queue.removeFirst()
    }
}

struct StubCalToken: AccessTokenProviding {
    let token: String
    func validAccessToken() async throws -> String { token }
}
```

- [ ] **Step 3: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AvailabilityProvidingTests
```

Expected: failure — `AvailabilityProviding` / `CalendarAvailabilityProvider` undefined (and/or `no such module 'SenaniCalendar'` until Step 1 lands).

- [ ] **Step 4: Implement the seam + production adapter**

Create `Packages/SenaniEngine/Sources/SenaniEngine/AvailabilityProviding.swift`:

```swift
import Foundation
import SenaniCalendar

/// Narrow async seam giving an Agent read-only access to the user's busy time, without holding
/// a CalendarClient / HTTPClient / token. The composition root injects a concrete provider.
public protocol AvailabilityProviding: Sendable {
    /// Busy intervals overlapping the window, ascending by start.
    func busyIntervals(in range: DateRange) async throws -> [FreeBusyInterval]
}

/// Production adapter: wraps `SenaniCalendar.CalendarClient.freeBusy(range:)`. This is the ONLY
/// SenaniEngine type that imports SenaniCalendar; the Booking agent depends only on the seam.
public struct CalendarAvailabilityProvider: AvailabilityProviding {
    private let client: CalendarClient
    public init(client: CalendarClient) { self.client = client }

    public func busyIntervals(in range: DateRange) async throws -> [FreeBusyInterval] {
        try await client.freeBusy(range: range).sorted { $0.start < $1.start }
    }
}
```

> `DateRange` / `FreeBusyInterval` are `SenaniCalendar` value types re-exported through this file's `import SenaniCalendar`; the Booking agent and its tests `import SenaniCalendar` to name them. They carry no Google/HTTP coupling — they are plain `Sendable` structs.

- [ ] **Step 5: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter AvailabilityProvidingTests
```

Expected: both pass.

- [ ] **Step 6: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: AvailabilityProviding seam + CalendarAvailabilityProvider adapter (wraps SenaniCalendar)

Adds ../SenaniCalendar path dep. The Booking agent depends only on the seam, never on the connector.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Booking fixtures + slot-config value type

**Files:**
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingFixtures.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/RecordingTextGenerator.swift` (only if the Reply-Drafter plan did not already add one to the test target — check first)

Shared helpers for the Booking tests: message/context builders + canned availability. Also pins the deterministic test "now" and time zone so slot assertions are stable.

- [ ] **Step 0: Check for an existing RecordingTextGenerator**

```
ls /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine/Tests/SenaniEngineTests/**/RecordingTextGenerator.swift 2>/dev/null && echo EXISTS || echo ABSENT
```
- **If `EXISTS`** (Reply-Drafter plan added it): do NOT create a second one — reuse it. Skip creating `Booking/RecordingTextGenerator.swift`.
- **If `ABSENT`:** create the file in Step 2.

- [ ] **Step 1: Create `BookingFixtures.swift`** (shared helpers, no `@Test`):

```swift
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniCalendar

enum BK {
    static let account = "ramesh@quantana.in"
    /// Fixed "now": Wed 2023-11-15 08:00:00 UTC. Tests use UTC business hours for determinism.
    static let now = CalendarHTTP.date(from: "2023-11-15T08:00:00Z")!
    static let utc = TimeZone(identifier: "UTC")!

    /// An incoming message explicitly triaged into the Booking category (label).
    static func bookingLabeled(
        id: String = "m-book",
        from: String = "sarah@client.com",
        subject: String = "Can we meet next week?",
        body: String = "Hi Ramesh, do you have 30 minutes to discuss the proposal?",
        threadId: String = "t1"
    ) -> Message {
        Message(id: id, from: from, to: [account], subject: subject, body: body,
                hasAttachment: false, listUnsubscribeHeader: nil, labels: ["Booking"],
                threadId: threadId, date: now, isFromUser: false)
    }

    /// An incoming message with meeting-intent wording but NO Booking label.
    static func meetingIntent(
        subject: String = "Quick call?",
        body: String = "Could we schedule a call to sync on timelines?"
    ) -> Message {
        Message(id: "m-intent", from: "sarah@client.com", to: [account], subject: subject, body: body,
                hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                threadId: "t2", date: now, isFromUser: false)
    }

    /// An unrelated message: no Booking label, no meeting wording.
    static func unrelated() -> Message {
        Message(id: "m-other", from: "newsletter@x.com", to: [account], subject: "Your weekly digest",
                body: "Here are this week's top stories.", hasAttachment: false,
                listUnsubscribeHeader: "<mailto:u@x.com>", labels: ["Newsletter"],
                threadId: "t3", date: now, isFromUser: false)
    }

    static func context(_ message: Message) -> AgentContext {
        AgentContext(account: account, thread: [message], rules: [],
                     retrieve: { _, _ in [] }, now: now)
    }

    /// Busy on Wed 09:00–10:00 and 13:00–14:00 UTC (mirrors CalendarClient fixtures).
    static func cannedBusy() -> [FreeBusyInterval] {
        [FreeBusyInterval(start: CalendarHTTP.date(from: "2023-11-15T09:00:00Z")!,
                          end: CalendarHTTP.date(from: "2023-11-15T10:00:00Z")!),
         FreeBusyInterval(start: CalendarHTTP.date(from: "2023-11-15T13:00:00Z")!,
                          end: CalendarHTTP.date(from: "2023-11-15T14:00:00Z")!)]
    }
}
```

- [ ] **Step 2: (Only if ABSENT in Step 0) Create `Booking/RecordingTextGenerator.swift`:**

```swift
import Foundation
import SenaniInference

/// Local prompt-recording TextGenerator (SenaniInference ships no fakes). Returns a canned body
/// and records each prompt so polish-path tests can assert the slots were threaded in.
final class RecordingTextGenerator: TextGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private let cannedBody: String
    private var prompts: [String] = []
    init(cannedBody: String) { self.cannedBody = cannedBody }
    func generate(prompt: String, maxTokens: Int) async throws -> String {
        lock.lock(); defer { lock.unlock() }; prompts.append(prompt); return cannedBody
    }
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        lock.lock(); defer { lock.unlock() }; prompts.append(prompt); return "{}"
    }
    var recordedPrompts: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    var lastPrompt: String? { recordedPrompts.last }
}
```

- [ ] **Step 3: Run to build**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift build --build-tests
```

Expected: compiles (fixtures reference only existing types). No tests run yet. (If a duplicate `RecordingTextGenerator` symbol error appears, the Reply-Drafter one already exists — delete the Booking copy and reuse it.)

- [ ] **Step 4: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: Booking test fixtures (messages, context, canned availability)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — BookingAgent `wakesFor` (trigger predicate)

**Files:**
- Create: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/BookingAgent.swift`
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingWakesForTests.swift`

`wakesFor` is a pure predicate: wakes when the message carries the **`"Booking"`** category label (set by Triage) OR its subject/body contains meeting-intent keywords ("meet", "meeting", "schedule", "call", "calendar", "availability", "time to"), and the message is NOT from the user. This task implements the agent shell + `wakesFor` + identity; `proposals` is fleshed out in Tasks 8–9 (start with a stub returning `[]` so it compiles).

- [ ] **Step 1: Write failing `wakesFor` tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingWakesForTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct BookingWakesForTests {
    private func agent() -> BookingAgent {
        BookingAgent(availability: FakeAvailabilityProvider(busy: []), generator: nil, timeZone: BK.utc)
    }

    @Test func wakesForBookingLabeledMessage() {
        let m = BK.bookingLabeled()
        #expect(agent().wakesFor(m, context: BK.context(m)) == true)
    }

    @Test func wakesForMeetingIntentWithoutLabel() {
        let m = BK.meetingIntent()
        #expect(agent().wakesFor(m, context: BK.context(m)) == true)
    }

    @Test func doesNotWakeForUnrelatedMessage() {
        let m = BK.unrelated()
        #expect(agent().wakesFor(m, context: BK.context(m)) == false)
    }

    @Test func doesNotWakeForMessageFromTheUser() {
        // A Booking-labeled message we ourselves sent must not trigger a self-reply.
        let m = Message(id: "mine", from: BK.account, to: ["sarah@client.com"], subject: "Can we meet?",
                        body: "When works?", hasAttachment: false, listUnsubscribeHeader: nil,
                        labels: ["Booking"], threadId: "t1", date: BK.now, isFromUser: true)
        #expect(agent().wakesFor(m, context: BK.context(m)) == false)
    }

    @Test func identityAndAutonomy() {
        let a = agent()
        #expect(a.id == "booking")
        #expect(a.autonomy == .prepare)   // outbound reply still ALWAYS queues regardless
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter BookingWakesForTests
```

Expected: compile error — `cannot find 'BookingAgent' in scope`.

- [ ] **Step 3: Implement the agent shell + `wakesFor`**

Create `Packages/SenaniEngine/Sources/SenaniEngine/Agents/BookingAgent.swift`:

```swift
import Foundation
import SenaniRules
import SenaniInference
import SenaniCalendar

/// Phase-2 Booking agent. Wakes for messages triaged into the "Booking" category (a label) or
/// that ask to meet, reads the user's free/busy through the injected `AvailabilityProviding` seam,
/// picks THREE concrete non-conflicting business-hours slots, and proposes them via ONE outbound
/// `reply` Action. `Action.reply` is `ActionClass.outbound`, so `ActionRouter.route` ALWAYS yields
/// `.queuedForApproval` — the agent NEVER auto-sends and NEVER books. (A real tentative hold needs
/// a new SenaniRules.Action case — §5 — and is deferred.)
public struct BookingAgent: Agent {
    public let id = "booking"
    /// Per-agent dial. Irrelevant to safety here: the emitted action is outbound, which
    /// `ActionRouter` queues regardless of autonomy.
    public let autonomy: Autonomy = .prepare

    /// The category label Triage assigns to scheduling mail.
    public static let category = "Booking"
    /// Keywords that signal meeting intent when no Booking label is present.
    static let meetingKeywords = ["meet", "meeting", "schedule", "scheduling",
                                  "call", "calendar", "availability", "time to", "catch up"]

    private let availability: any AvailabilityProviding
    private let generator: (any TextGenerator)?
    private let timeZone: TimeZone
    let config: SlotConfig

    public init(
        availability: any AvailabilityProviding,
        generator: (any TextGenerator)? = nil,
        timeZone: TimeZone = .current,
        config: SlotConfig = .default
    ) {
        self.availability = availability
        self.generator = generator
        self.timeZone = timeZone
        self.config = config
    }

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        guard !message.isFromUser else { return false }
        if message.labels.contains(Self.category) { return true }
        let haystack = (message.subject + " " + message.body).lowercased()
        return Self.meetingKeywords.contains { haystack.contains($0) }
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        // Implemented in Tasks 8–9.
        []
    }
}

/// Tunable slot-selection policy (pure data — no I/O).
public struct SlotConfig: Sendable, Equatable {
    public let slotMinutes: Int           // proposed meeting length
    public let businessStartHour: Int     // inclusive, in the agent's time zone
    public let businessEndHour: Int       // exclusive
    public let searchDays: Int            // how many days forward to scan
    public let slotsToPropose: Int        // how many slots to offer

    public init(slotMinutes: Int = 30, businessStartHour: Int = 9, businessEndHour: Int = 17,
                searchDays: Int = 7, slotsToPropose: Int = 3) {
        self.slotMinutes = slotMinutes
        self.businessStartHour = businessStartHour
        self.businessEndHour = businessEndHour
        self.searchDays = searchDays
        self.slotsToPropose = slotsToPropose
    }

    public static let `default` = SlotConfig()
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter BookingWakesForTests
```

Expected: all 5 pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: BookingAgent shell + wakesFor (Booking category or meeting-intent keywords)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — Pure slot selection (3 non-conflicting business-hours slots)

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/BookingAgent.swift` (add the pure slot picker)
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingSlotSelectionTests.swift`

The slot picker is a **pure static function** `BookingAgent.pickSlots(now:busy:config:timeZone:)` so it is unit-testable with no network/clock. Algorithm: from `now`, walk each business day forward; within each day enumerate candidate `slotMinutes` slots from `businessStartHour` to `businessEndHour` (on the slot grid); skip any slot starting in the past or overlapping a busy interval; collect until `slotsToPropose` are found. Times computed in the injected `timeZone`.

- [ ] **Step 1: Write failing slot-selection tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingSlotSelectionTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniCalendar

@Suite struct BookingSlotSelectionTests {
    private func d(_ s: String) -> Date { CalendarHTTP.date(from: s)! }

    @Test func picksThreeNonConflictingBusinessHoursSlots() {
        // now = Wed 08:00Z (before business hours). Busy 09:00–10:00 and 13:00–14:00.
        // First three free 30-min slots from 09:00 grid: 10:00, 10:30, 11:00.
        let slots = BookingAgent.pickSlots(
            now: BK.now,
            busy: BK.cannedBusy(),
            config: .default,
            timeZone: BK.utc
        )
        #expect(slots.count == 3)
        #expect(slots[0].start == d("2023-11-15T10:00:00Z"))
        #expect(slots[1].start == d("2023-11-15T10:30:00Z"))
        #expect(slots[2].start == d("2023-11-15T11:00:00Z"))
        // Each is exactly slotMinutes long.
        #expect(slots.allSatisfy { $0.duration == 30 * 60 })
        // None overlaps a busy interval.
        for s in slots {
            for b in BK.cannedBusy() {
                #expect(!(s.start < b.end && b.start < s.end))
            }
        }
    }

    @Test func skipsSlotsStartingInThePast() {
        // now = Wed 11:15Z → the 11:00 slot is partly past; first candidate is 11:30.
        let now = d("2023-11-15T11:15:00Z")
        let slots = BookingAgent.pickSlots(now: now, busy: BK.cannedBusy(), config: .default, timeZone: BK.utc)
        #expect(slots.first?.start == d("2023-11-15T11:30:00Z"))
        #expect(slots.allSatisfy { $0.start >= now })
    }

    @Test func rollsToTheNextBusinessDayWhenADayHasTooFewSlots() {
        // Busy the entire Wed business day → all three slots fall on Thu starting 09:00.
        let fullDay = [FreeBusyInterval(start: d("2023-11-15T09:00:00Z"), end: d("2023-11-15T17:00:00Z"))]
        let slots = BookingAgent.pickSlots(now: BK.now, busy: fullDay, config: .default, timeZone: BK.utc)
        #expect(slots.count == 3)
        #expect(slots[0].start == d("2023-11-16T09:00:00Z"))
        #expect(slots[1].start == d("2023-11-16T09:30:00Z"))
    }

    @Test func returnsFewerThanRequestedWhenWindowIsExhausted() {
        // searchDays = 1 and the whole day is busy → no slots.
        let fullDay = [FreeBusyInterval(start: d("2023-11-15T09:00:00Z"), end: d("2023-11-15T17:00:00Z"))]
        let cfg = SlotConfig(slotMinutes: 30, businessStartHour: 9, businessEndHour: 17, searchDays: 1, slotsToPropose: 3)
        let slots = BookingAgent.pickSlots(now: BK.now, busy: fullDay, config: cfg, timeZone: BK.utc)
        #expect(slots.isEmpty)
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter BookingSlotSelectionTests
```

Expected: compile error — `pickSlots` undefined.

- [ ] **Step 3: Implement `pickSlots`**

Add to `BookingAgent` in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/BookingAgent.swift` (inside the struct, after `proposals`):

```swift
    // MARK: - Pure slot selection (no I/O — independently testable)

    /// Walk business days from `now`, enumerate `slotMinutes` slots on the grid within business
    /// hours, skip past or busy-overlapping slots, and collect up to `config.slotsToPropose`.
    /// Returns fewer if the window is exhausted. Deterministic given the inputs.
    public static func pickSlots(
        now: Date,
        busy: [FreeBusyInterval],
        config: SlotConfig,
        timeZone: TimeZone
    ) -> [CalendarSlot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let slotLength = TimeInterval(config.slotMinutes * 60)
        let sortedBusy = busy.sorted { $0.start < $1.start }
        var found: [CalendarSlot] = []

        for dayOffset in 0..<config.searchDays {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            // First slot of this business day.
            guard var cursor = calendar.date(
                bySettingHour: config.businessStartHour, minute: 0, second: 0, of: dayStart
            ) else { continue }
            guard let dayEnd = calendar.date(
                bySettingHour: config.businessEndHour, minute: 0, second: 0, of: dayStart
            ) else { continue }

            while cursor.addingTimeInterval(slotLength) <= dayEnd {
                let slotEnd = cursor.addingTimeInterval(slotLength)
                let inFuture = cursor >= now
                let overlapsBusy = sortedBusy.contains { $0.start < slotEnd && cursor < $0.end }
                if inFuture && !overlapsBusy {
                    found.append(CalendarSlot(start: cursor, end: slotEnd))
                    if found.count == config.slotsToPropose { return found }
                }
                cursor = slotEnd
            }
        }
        return found
    }
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter BookingSlotSelectionTests
```

Expected: all 4 pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: BookingAgent.pickSlots — pure business-hours, busy-aware slot selection

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9 — BookingAgent `proposals` (emit ONE outbound reply with 3 slots)

**Files:**
- Edit: `Packages/SenaniEngine/Sources/SenaniEngine/Agents/BookingAgent.swift` (implement `proposals`)
- Create: `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingProposalsTests.swift`

`proposals`: if `wakesFor` is false, return `[]` (no model/seam call wasted). Else compute the forward window `[now, now + searchDays]`, ask the seam for busy intervals, `pickSlots`, render the slots into a reply body (human-readable, in the agent's time zone), optionally polish via the injected `TextGenerator`, and return `[tools.reply(to: message, body: body)]` (or `tools.draftReply(...)` if that is the on-disk builder name — both map to `.reply`). If no slots are found, propose a fallback reply asking for the recipient's availability (still ONE outbound reply). Always exactly one outbound action.

- [ ] **Step 0: Confirm the outbound tool builder name**

```
grep -nE "func (reply|draftReply)\(" /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine/Sources/SenaniEngine/*.swift
```
Note which exists (`reply(to:body:)` per §3, or `draftReply(to:body:)` per the Reply-Drafter plan). Use that name in `proposals` below; both return `Action.reply(body:)`. If neither exists, construct `Action.reply(body:)` directly and record the deviation.

- [ ] **Step 1: Write failing `proposals` tests**

Create `Packages/SenaniEngine/Tests/SenaniEngineTests/Booking/BookingProposalsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules
import SenaniCalendar

@Suite struct BookingProposalsTests {
    private func agent(busy: [FreeBusyInterval], generator: (any SenaniInferenceTextGen)? = nil) -> BookingAgent {
        BookingAgent(availability: FakeAvailabilityProvider(busy: busy),
                     generator: generator as? RecordingTextGenerator,
                     timeZone: BK.utc)
    }

    @Test func emitsExactlyOneOutboundReplyProposingThreeSlots() async throws {
        let provider = FakeAvailabilityProvider(busy: BK.cannedBusy())
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.bookingLabeled()

        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: AgentTools())

        #expect(actions.count == 1)
        #expect(actions.first?.actionClass == .outbound)   // ⇒ ActionRouter ALWAYS queues it
        // It is a .reply carrying all three slot times.
        guard case let .reply(body) = actions.first else { Issue.record("not a reply"); return }
        #expect(body.contains("10:00"))
        #expect(body.contains("10:30"))
        #expect(body.contains("11:00"))
        // The seam was queried for a forward window starting at `now`.
        #expect(provider.recordedWindows.first?.start == BK.now)
    }

    @Test func neverBooksAndNeverAutoSends() async throws {
        // The agent returns only an outbound reply; it builds no hold and performs no calendar write.
        let provider = FakeAvailabilityProvider(busy: BK.cannedBusy())
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.bookingLabeled()
        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: AgentTools())
        // Exactly one action, and it is outbound (queues) — no executed side effect, no .runAgent, no insert.
        #expect(actions.count == 1)
        #expect(actions.allSatisfy { $0.actionClass == .outbound })
    }

    @Test func returnsNoProposalsForNonBookingMessage() async throws {
        let provider = FakeAvailabilityProvider(busy: [])
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.unrelated()
        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: AgentTools())
        #expect(actions.isEmpty)
        // The seam was never queried (no wasted availability fetch).
        #expect(provider.recordedWindows.isEmpty)
    }

    @Test func fallsBackToAskingForAvailabilityWhenNoSlotsFree() async throws {
        // Whole week busy → no slots → still ONE outbound reply, asking the sender for their availability.
        let busyWeek = (0..<7).map { day -> FreeBusyInterval in
            let start = CalendarHTTP.date(from: "2023-11-15T00:00:00Z")!.addingTimeInterval(Double(day) * 86_400)
            return FreeBusyInterval(start: start, end: start.addingTimeInterval(86_400))
        }
        let provider = FakeAvailabilityProvider(busy: busyWeek)
        let agent = BookingAgent(availability: provider, generator: nil, timeZone: BK.utc)
        let m = BK.bookingLabeled()
        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: AgentTools())
        #expect(actions.count == 1)
        #expect(actions.first?.actionClass == .outbound)
        guard case let .reply(body) = actions.first else { Issue.record("not a reply"); return }
        #expect(body.lowercased().contains("availability"))
    }

    @Test func usesGeneratorToPolishWhenProvidedAndThreadsSlotsIntoPrompt() async throws {
        let gen = RecordingTextGenerator(cannedBody: "Happy to meet! Here are some times that work for me.")
        let provider = FakeAvailabilityProvider(busy: BK.cannedBusy())
        let agent = BookingAgent(availability: provider, generator: gen, timeZone: BK.utc)
        let m = BK.bookingLabeled()

        let actions = try await agent.proposals(for: m, context: BK.context(m), tools: AgentTools())

        guard case let .reply(body) = actions.first else { Issue.record("not a reply"); return }
        #expect(body.contains("Happy to meet"))      // generator output used
        let prompt = try #require(gen.lastPrompt)
        #expect(prompt.contains("10:00"))            // the chosen slots were given to the model
    }
}

/// Local alias so the test signature reads clearly; RecordingTextGenerator conforms to it.
typealias SenaniInferenceTextGen = SenaniInference.TextGenerator
import SenaniInference
```

> If the test file's trailing `import SenaniInference` causes an "imports must precede declarations" error, move both the `import SenaniInference` line and the `typealias` to the TOP of the file. (Kept inline here only to show intent.)

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter BookingProposalsTests
```

Expected: failures — `proposals` still returns `[]` (the stub), so the slot/reply assertions fail.

- [ ] **Step 3: Implement `proposals` (+ rendering)**

Replace the stub `proposals` in `BookingAgent` and add the private renderers:

```swift
    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }

        let window = DateRange(
            start: context.now,
            end: context.now.addingTimeInterval(TimeInterval(config.searchDays * 86_400))
        )
        let busy = try await availability.busyIntervals(in: window)
        let slots = Self.pickSlots(now: context.now, busy: busy, config: config, timeZone: timeZone)

        let body: String
        if slots.isEmpty {
            body = fallbackBody(for: message)
        } else if let generator {
            let prompt = polishPrompt(slots: slots, message: message)
            let raw = try await generator.generate(prompt: prompt, maxTokens: Self.maxReplyTokens)
            let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Always append the concrete slot lines so the proposal is unambiguous even if the model omits them.
            body = polished.isEmpty ? slotBody(slots: slots) : polished + "\n\n" + renderSlotLines(slots)
        } else {
            body = slotBody(slots: slots)
        }

        return [tools.reply(to: message, body: body)]   // use draftReply(...) instead if that is the on-disk builder name (both map to .reply)
    }

    static let maxReplyTokens = 256

    // MARK: - Reply rendering (pure)

    private func slotBody(slots: [CalendarSlot]) -> String {
        "Thanks for reaching out — I'd be glad to meet. Here are a few times that work for me:\n\n"
            + renderSlotLines(slots)
            + "\n\nLet me know which suits you and I'll confirm."
    }

    private func renderSlotLines(_ slots: [CalendarSlot]) -> String {
        slots.map { "• " + format($0) }.joined(separator: "\n")
    }

    private func fallbackBody(for message: Message) -> String {
        "Thanks for reaching out — I'd be glad to meet. My calendar is quite full over the next few days; "
            + "could you share a couple of times that suit your availability and I'll confirm one?"
    }

    private func polishPrompt(slots: [CalendarSlot], message: Message) -> String {
        """
        Write a brief, friendly reply offering these meeting times (in my voice). \
        Keep it to two short sentences and do NOT invent times.

        Their message subject: \(message.subject)
        Proposed times:
        \(renderSlotLines(slots))
        """
    }

    private func format(_ slot: CalendarSlot) -> String {
        let df = DateFormatter()
        df.timeZone = timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE d MMM, HH:mm"
        let start = df.string(from: slot.start)
        let timeOnly = DateFormatter()
        timeOnly.timeZone = timeZone
        timeOnly.locale = Locale(identifier: "en_US_POSIX")
        timeOnly.dateFormat = "HH:mm"
        return "\(start)–\(timeOnly.string(from: slot.end))"
    }
```

> The `format` output includes the `HH:mm` start time (e.g. `Wed 15 Nov, 10:00–10:30`), so the tests' `body.contains("10:00")` assertions hold against the UTC time zone the tests inject.

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test --filter BookingProposalsTests
```

Expected: all 5 pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniEngine: BookingAgent.proposals — one outbound reply offering 3 slots (or asks availability)

Outbound Action.reply always queues; agent never books and never auto-sends. Optional generator polish.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10 — Full-suite green + public-surface + composition-root note

**Files:** none (verification + a documentation note for the app-shell plan).

- [ ] **Step 1: Run the full SenaniCalendar suite**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniCalendar && swift test
```
Expected: all green (`ScopesProbeTests`, `CalendarModelsTests`, `CalendarEndpointsTests`, `CalendarClientTests`). Strict-concurrency clean.

- [ ] **Step 2: Run the full SenaniEngine suite**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && swift test
```
Expected: all green, including the new `AvailabilityProvidingTests`, `BookingWakesForTests`, `BookingSlotSelectionTests`, `BookingProposalsTests`, AND all pre-existing engine/agent suites (Orchestrator, Reply-Drafter, Triage, etc.) — the added `../SenaniCalendar` dep and Booking files must not break them.

- [ ] **Step 3: Confirm public surface** matches the contract:
  - `SenaniCalendar`: `CalendarScopes`, `DateRange`, `FreeBusyInterval`, `CalendarEvent`, `CalendarSlot`, `TentativeHoldDraft`, `CalendarEndpoints`, `CalendarHTTP`, `CalendarClient` (`freeBusy`/`listEvents`/`proposeHold`).
  - `SenaniEngine`: `AvailabilityProviding`, `CalendarAvailabilityProvider`, `BookingAgent` (`id == "booking"`, `autonomy == .prepare`), `SlotConfig`.

- [ ] **Step 4: Record the composition-root wiring note** (for the app-shell plan — do NOT implement here). In the commit body, document the one-time wiring the app-shell plan must do:
  ```
  // In AppEnvironment.live():
  //   let calendarClient = CalendarClient(http: urlSessionHTTP, tokenProvider: gmail /* GmailAuth */)
  //   let availability  = CalendarAvailabilityProvider(client: calendarClient)
  //   let booking       = BookingAgent(availability: availability, generator: generator, timeZone: .current)
  //   // register `booking` in the AgentRegistry under the "Booking" category (its wakesFor matches the label)
  // Re-consent: append CalendarScopes.all to GmailAuth.authorizationURL(scopes:) in the onboarding flow.
  ```

- [ ] **Step 5: Commit (verification marker)**

```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniEngine && git add -A && git commit -q --allow-empty -m "$(cat <<'EOF'
SenaniEngine + SenaniCalendar: Booking suites green; public contract verified

Composition root (app-shell plan): build CalendarClient over GmailAuth, wrap in
CalendarAvailabilityProvider, construct BookingAgent, register under "Booking" category.
Append CalendarScopes.all to the consent URL (re-consent required).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Scope coverage (brief):**
- **NEW `SenaniCalendar` package** mirroring `SenaniGmail`: a `CalendarClient` over the injected `HTTPClient` + `AccessTokenProviding` (REUSED from `SenaniGmail`, not re-declared, so one OAuth token drives both connectors), with `freeBusy(range:)`, `listEvents(range:)`, and `proposeHold(...)` building a tentative/`status:"tentative"` event request. New-package-vs-module decision justified (connectors tier, mirrors `SenaniGmail`, keeps the agent pure). ✅
- **OAuth scope addition** (`calendar.readonly` + `calendar.events`) declared in `CalendarScopes`; **re-consent requirement** flagged to the human (§5) and documented for the onboarding plan to append to `GmailAuth.authorizationURL(scopes:)`. ✅
- **`BookingAgent: SenaniEngine.Agent`** co-located in `Packages/SenaniEngine/Sources/SenaniEngine/Agents/`, coded to the §3 contract. `wakesFor` triggers on the `"Booking"` category label OR meeting-intent keywords, never for the user's own messages. Reads availability via the injected `AvailabilityProviding` seam (NOT a new `AgentContext` field — Booking needs none; the seam keeps the agent pure per §4). Picks **3** non-conflicting business-hours slots and emits ONE **outbound** `reply` Action → `ActionRouter` ALWAYS queues it (verified `Routing.swift`: outbound short-circuits to `.queuedForApproval`). Never auto-sends, never books. ✅
- **Real tentative hold deferred:** writing a hold needs a new `SenaniRules.Action` case the frozen enum lacks; per §5 this is a blocking change requiring human sign-off. The plan does NOT fork the action model — it ships only `proposeHold`'s request builder (never sent) and routes only the outbound reply. Flagged below. ✅

**Real-source reconciliations (verified, recorded in the plan):**
1. `SenaniGmail.HTTPClient` / `AccessTokenProviding` / `HTTPClientError` are PUBLIC and reused by `SenaniCalendar` (no second seam). `GmailAuth.validate(response:data:)` is INTERNAL → `SenaniCalendar` re-implements the same check in `CalendarHTTP.validate`, throwing the public `HTTPClientError.unexpectedStatus`. ✅
2. `SenaniRules.Action` has `.reply` (outbound) but **no calendar/hold case** → `AgentTools.reply(to:body:)` → `.reply` (always queues); hold deferred to §5. ✅
3. `AgentTools` outbound builder may be named `reply` (§3) or `draftReply` (Reply-Drafter plan) — both return `.reply`. Task 9 Step 0 verifies the on-disk name and Task 9 wires whichever exists; the outbound guarantee holds via `actionClass` regardless. ✅
4. `SenaniInference` ships NO fakes → local `RecordingTextGenerator` (reused from Reply-Drafter if present, else created). `SenaniGmail`/`SenaniCalendar` ship no public HTTP fakes → local `FakeHTTPClient` in each test target. ✅
5. `SenaniEngine` must already exist (orchestrator plan); this plan does NOT scaffold it (Task 5 Step 0 / Task 7 guard) — a shared-package coordination point. ✅

**Tests (pure, no MLX/Gmail/Google network):**
- `SenaniCalendar`: fake `HTTPClient` returns canned freeBusy/events JSON → `CalendarClient` parses busy intervals + timed events (skips all-day), throws on HTTP error, and `proposeHold` builds a draft+request **without sending** (asserted: `recordedRequests.isEmpty`). Endpoint builders assert URL/method/Bearer/body shape. ✅
- `SenaniEngine` Booking: fake `AvailabilityProviding` (canned busy) + fake `TextGenerator`. Asserts: 3 non-conflicting slots chosen (pure `pickSlots`, incl. past-skip, day-rollover, exhaustion); exactly ONE **outbound** `reply` produced (so it queues); agent does NOT wake / yields no proposals + no seam call for non-booking messages; fallback reply when fully busy; generator-polish path threads slots into the prompt. ✅

**Conventions (§4):** agent is pure (only injected seam + optional generator I/O); ONE safety path (outbound → `ActionRouter` queues, never a second path, never auto-book); reads through context/seam, never stores; composition-root-only wiring documented for the app-shell plan (no screen/agent builds a `CalendarClient`); macOS 14 / Swift 6.2 / strict concurrency / Swift Testing; TDD bite-sized steps with complete code, run-to-fail/run-to-pass commands + expected output, frequent commits with the standard trailer. ✅

**Open items flagged to the human (§5):**
- **Calendar OAuth scopes + re-consent** — adding `calendar.readonly` + `calendar.events` to the existing Gmail consent expands scope and forces Google re-consent; the onboarding plan must append `CalendarScopes.all` to `authorizationURL(scopes:)`. The human supplies/confirms the OAuth desktop client allows Calendar scopes.
- **New `Action` case for a real tentative hold (BLOCKING, §5)** — auto-creating a Google Calendar hold needs an outbound `SenaniRules.Action` (e.g. `.calendarHold(calendarId:title:start:end:)`) the frozen enum lacks. Decide: extend + re-freeze `SenaniRules.Action` (then add a `proposeHold` tool + Orchestrator routing + a Calendar mail-backend executor) vs. keep proposals-only. Until signed off, Phase-2 Booking proposes slots via the outbound reply only; `CalendarClient.proposeHold` is built and tested but never routed/sent.
- **`SenaniEngine` ownership / shared package** — coordinate with the orchestrator + Triage + Reply-Drafter plans so only one plan scaffolds `SenaniEngine`/edits its `Package.swift`; this plan only ADDS the `../SenaniCalendar` dep + the `Agents/BookingAgent.swift`/`AvailabilityProviding.swift` files.
- **`AgentTools` builder name** (`reply` vs `draftReply`) — confirm against the on-disk file (Task 9 Step 0); both map to `.reply`.
