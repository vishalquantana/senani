# Gmail OAuth + Onboarding (Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the live Gmail OAuth 2.0 desktop/loopback consent flow into the Senani macOS app: generate PKCE, build the consent URL with the Gmail read/modify/compose scopes, open it in the browser, capture the redirect `code` via a transient localhost loopback HTTP listener, exchange it for tokens through the **already-built-and-frozen** `SenaniGmail.GmailAuth`, persist them in the macOS Keychain, surface the connected account email in the app's composition root, and let Settings disconnect (clear the token). All testable logic — PKCE round-trip, consent-URL composition, code exchange, refresh-on-expiry, sign-out — is unit-tested with `InMemoryTokenStore`, a fake `HTTPClient`, and a fake loopback capture; **no real network, browser, or Keychain runs in tests.**

**Architecture:** This is **app-tier** work that builds on the existing `SenaniApp/` executable scaffold; it does **NOT** edit the frozen `SenaniGmail` package. A new app-internal type `GmailOAuthFlow` orchestrates one consent round-trip: `PKCE.random()` → `GmailAuth.authorizationURL(...)` → open in browser → run a `LoopbackListener` (transient `127.0.0.1` HTTP server) → extract `code` + verify `state` → `GmailAuth.authenticate(code:redirectURI:verifier:)` (which persists via the injected `TokenStore`) → return the connected account email. The browser-opening and the socket-level listening sit behind two protocols (`BrowserOpening`, `LoopbackCapturing`) so the orchestration is fully unit-testable with fakes; the real implementations (`NSWorkspace.open`, an `NWListener`-based capture) are thin and exercised only by an env-gated manual integration test. The connected account email is read from the userinfo endpoint via the same `HTTPClient` seam. Per §4 of the reconciliation doc, the **composition root constructs `GmailAuth`** and screens receive it; this plan extends the scaffold's `AppState` composition root with a `GmailAccount` connection-state object and injects it into a `ConnectAccountView` (onboarding) and a Settings disconnect control — no screen constructs a `TokenStore`, `GmailAuth`, or reads the Keychain directly.

**Tech Stack:** Swift 6.2 (the `SenaniApp` executable manifest is `swift-tools-version: 5.9`, macOS 14; match it — do NOT bump it), SwiftPM, Swift Testing (`import Testing`), SwiftUI, `Foundation` + `Network` (`NWListener` for loopback) + `AppKit` (`NSWorkspace`) — system frameworks only. Depends on the frozen `SenaniGmail` package already referenced by `SenaniApp/Package.swift`. Raw OAuth at `https://accounts.google.com/o/oauth2/v2/auth` + `https://oauth2.googleapis.com/token`; userinfo at `https://www.googleapis.com/oauth2/v3/userinfo`.

**Working directory:** All `swift build` / `swift test` commands run from `/Users/vishalkumar/Downloads/qmail/SenaniApp/` unless stated otherwise. The `SenaniApp` package is an **executable** with no test target today; **Task 1 adds a `SenaniAppTests` test target** to the manifest so the app-tier logic is unit-testable. Source files live under `SenaniApp/Sources/SenaniApp/`; tests under `SenaniApp/Tests/SenaniAppTests/`.

**Design spec / authority:** This plan implements the **Gmail OAuth + onboarding** node of `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` (the authoritative app-layer reconciliation). It honors §2 (real `SenaniGmail` signatures), §3 (composition root owns `GmailAuth`), §4 (composition-root-only wiring, one safety path, live/preview parity, macOS 14 / Swift Testing / TDD), and resolves the §5 **OAuth client-ID open pin** (see Task 2).

**Out of scope (separate plans):** The full `AppEnvironment.live()/.preview()` composition root with the orchestrator/scheduler/MLX graph (owned by the app-shell + engine plans — this plan extends the *existing* `AppState` scaffold and leaves a documented seam for `AppEnvironment` to absorb later); `GmailSync` message ingestion into the store (owned by the gmail-backend-sync / store-bootstrap plans — `GmailSync` is frozen and already built); the gold-glass DesignSystem components (owned by the design-system plan — this plan uses plain SwiftUI and the existing `DesignSystem.swift`/`Theme.swift` scaffold, leaving styling to be re-skinned later); Calendar scope (added by the Booking plan).

---

## Cross-package assumptions (verified from `Packages/SenaniGmail/Sources/SenaniGmail/**` — state these to the human before coding)

This plan codes against the **real, current** `SenaniGmail` public API (read from source, not guessed). It does **NOT** edit `SenaniGmail`.

- **`PKCE` (in `GmailAuth.swift`):**
  ```swift
  public struct PKCE: Sendable, Equatable {
      public let verifier: String
      public init(verifier: String)
      public static func random() -> PKCE                 // 64-char unreserved-charset verifier
      public var challenge: String { get }                // base64url(SHA256(verifier)) via MIMEBuilder.base64URL — unpadded, url-safe
  }
  ```
- **`GmailAuth` (actor, conforms to `AccessTokenProviding`):**
  ```swift
  public actor GmailAuth: AccessTokenProviding {
      public init(clientID: String, http: any HTTPClient, store: any TokenStore, now: @escaping @Sendable () -> Date = Date.init)
      public static func authorizationURL(clientID: String, redirectURI: String, scopes: [String], pkce: PKCE, state: String) -> URL
      public static func tokenExchangeRequest(clientID: String, code: String, redirectURI: String, verifier: String) -> URLRequest
      public static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest
      public func validAccessToken() async throws -> String      // refreshes when needsRefresh(now:skew:60); throws .notAuthenticated when store empty
      public func authenticate(code: String, redirectURI: String, verifier: String) async throws   // exchanges + store.save; throws .notAuthenticated if no refresh_token returned
  }
  ```
  - ⚠ **`GmailAuth.init` is `(clientID:http:store:now:)`** — the exact signature this plan injects.
  - ⚠ `authorizationURL` already appends `access_type=offline` and `prompt=consent`. The plan does NOT re-add them.
  - ⚠ `authenticate(...)` throws `GmailAuthError.notAuthenticated` if Google's token response omits a `refresh_token`. The loopback flow MUST request offline access (it does, via `authorizationURL`) so the first consent returns a refresh token. Document that re-consent (not silent re-auth) is required if the refresh token is ever lost.
- **`GmailAuthError`:** `public enum GmailAuthError: Error, Equatable { case notAuthenticated, missingAuthorizationCode, stateMismatch }` — reuse `.stateMismatch` / `.missingAuthorizationCode` semantics in the app flow (the app defines its own `GmailOAuthError` for app-level failures; see Task 3).
- **`TokenStore` (in `Keychain.swift`):**
  ```swift
  public protocol TokenStore: Sendable {
      func load() async throws -> OAuthToken?
      func save(_ token: OAuthToken) async throws
      func clear() async throws                            // ← sign-out clears the token
  }
  public actor  InMemoryTokenStore: TokenStore { public init() }              // tests
  public struct KeychainTokenStore: TokenStore {                              // live
      public init(service: String = "in.quantana.senani.gmail", account: String = "default")
  }
  ```
- **`OAuthToken`:** `public struct OAuthToken: Sendable, Equatable, Codable { public var accessToken: String; public var refreshToken: String; public var expiresAt: Date; public func needsRefresh(now:skew:) -> Bool }`.
- **`HTTPClient` (in `HTTPClient.swift`):**
  ```swift
  public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
  public enum HTTPClientError: Error, Equatable { case noQueuedResponse, nonHTTPResponse, unexpectedStatus(Int, body: String) }
  public struct URLSessionHTTPClient: HTTPClient { public init(session: URLSession = .shared) }   // live
  ```
  - ⚠ `SenaniGmail` ships **no** public `FakeHTTPClient` (it lives in `SenaniGmailTests`, not exported). This plan defines its **own** `FakeHTTPClient` in `SenaniAppTests` (Task 1).
- **`GmailEndpoints` (in `GmailEndpoints.swift`):** `public enum GmailEndpoints { ... }` — its `authorizedRequest` is private. The plan only needs the OAuth statics on `GmailAuth`; for the userinfo call (account email) the app builds its own `URLRequest`.
- **Existing app scaffold (`SenaniApp/Sources/SenaniApp/`):** `SenaniApp.swift` defines `@main struct SenaniApp: App` and an `@Observable final class AppState { let database; let messageStore; let ruleStore; var selectedSidebarItem }` injected via `.environment(appState)`. `MainNavigationView.swift` reads `@Environment(AppState.self)`. This plan **extends `AppState`** (the de-facto composition root today) with the Gmail wiring; it does not introduce `AppEnvironment` (the app-shell plan owns that and will absorb this wiring later — leave a `// TODO(app-shell): fold GmailAccount into AppEnvironment` marker).

---

## Gmail OAuth scopes (pinned)

The consent flow requests exactly these scopes (read + modify + compose, per the brief), plus `email`/`openid` so the userinfo endpoint can return the connected account address:

```
https://www.googleapis.com/auth/gmail.readonly
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/gmail.compose
openid
email
```

> `gmail.modify` already implies label/archive/read-state writes; `gmail.compose` covers draft creation; `gmail.readonly` is retained for the sync read path. `openid email` lets the app read the account address without an extra Gmail call. These live in one place: `GmailOAuthConfig.scopes` (Task 2).

---

## Redirect URI (pinned)

Desktop/loopback flow uses an ephemeral loopback redirect: `http://127.0.0.1:<port>/oauth2redirect`, where `<port>` is chosen by the OS when the transient listener binds (port `0` → assigned). The exact `redirectURI` string passed to `authorizationURL` and `authenticate` is built from the bound port at runtime (`http://127.0.0.1:\(port)/oauth2redirect`). Google's installed-app OAuth client allows any loopback port, so no fixed port needs registering.

---

## File Structure

```
SenaniApp/
├── Package.swift                                  # EDIT: add SenaniAppTests test target (Task 1)
├── Sources/SenaniApp/
│   ├── SenaniApp.swift                            # EDIT: AppState gains gmailAuth + gmailAccount; first-run shows ConnectAccountView (Task 7)
│   ├── Gmail/
│   │   ├── GmailOAuthConfig.swift                 # client-ID resolution (env / Info.plist / gitignored file) + scopes + auth endpoint (Task 2)
│   │   ├── BrowserOpening.swift                   # BrowserOpening protocol + NSWorkspaceBrowserOpener (Task 3)
│   │   ├── LoopbackCapture.swift                  # LoopbackCapturing protocol + LoopbackResult + NWLoopbackListener (Task 4)
│   │   ├── GmailOAuthFlow.swift                   # orchestrates one consent round-trip → connected email (Task 5)
│   │   ├── GmailAccountInfo.swift                 # userinfo fetch (account email) behind HTTPClient (Task 5)
│   │   └── GmailAccount.swift                     # @MainActor @Observable connection-state surfaced in composition root (Task 6)
│   └── UI/
│       ├── ConnectAccountView.swift               # onboarding "Connect Gmail" screen (Task 7)
│       └── AccountSettingsView.swift              # Settings account row + Disconnect (Task 8)
└── Tests/SenaniAppTests/
    ├── TestSupport.swift                          # FakeHTTPClient, FakeBrowserOpener, FakeLoopbackCapture, canned-JSON helpers (Task 1)
    ├── GmailOAuthConfigTests.swift                # client-ID resolution + scopes (Task 2)
    ├── GmailOAuthFlowAuthURLTests.swift           # consent URL has scopes + challenge + loopback redirect (Task 5)
    ├── GmailOAuthFlowExchangeTests.swift          # capture code → authenticate stores token → returns email (Task 5)
    ├── GmailAuthRefreshTests.swift                # validAccessToken refreshes when expired (Task 5)
    ├── GmailAccountTests.swift                    # @MainActor state: connect sets .connected(email); disconnect clears (Task 6)
    └── PKCERoundTripTests.swift                   # PKCE verifier/challenge round-trip (Task 5, first test)
```

Each file has one responsibility. The orchestrator (`GmailOAuthFlow`) depends only on protocols (`HTTPClient`, `TokenStore`, `BrowserOpening`, `LoopbackCapturing`) plus the frozen `GmailAuth` static `authorizationURL` and the `GmailAuth` actor's `authenticate`. No screen constructs a store or backend.

**Conventions for every task below:**
- `<app>` = `/Users/vishalkumar/Downloads/qmail/SenaniApp`
- Run tests with: `cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test`
- Do NOT edit `../Packages/SenaniGmail` (or any frozen package). Import via `import SenaniGmail`.
- Commit trailer (append to EVERY commit message):

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

## Task 1 — Test target + test doubles (FakeHTTPClient, FakeBrowserOpener, FakeLoopbackCapture)

The `SenaniApp` executable has no test target. Add one and the shared fakes the rest of the plan uses. `SenaniGmail`'s own `FakeHTTPClient` is in *its* test target and not visible here, so this package ships its own.

**Files:**
- Edit: `SenaniApp/Package.swift` (add `SenaniAppTests` test target)
- Create: `SenaniApp/Tests/SenaniAppTests/TestSupport.swift`

**Steps:**

- [ ] **Step 1: Write a FAILING test** — create `SenaniApp/Tests/SenaniAppTests/TestSupport.swift` with the doubles AND a self-test:

```swift
import Testing
import Foundation
@testable import SenaniApp
import SenaniGmail

// ---- Test doubles ----

/// App-tier fake HTTP client: replays queued (data, status) FIFO and records sent requests.
actor FakeHTTPClient: HTTPClient {
    struct Queued { let data: Data; let status: Int; let url: URL }
    private var queue: [Queued] = []
    private(set) var recordedRequests: [URLRequest] = []

    func enqueueJSON(_ json: String, status: Int = 200,
                     url: URL = URL(string: "https://oauth2.googleapis.com/token")!) {
        queue.append(.init(data: Data(json.utf8), status: status, url: url))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queue.isEmpty else { throw HTTPClientError.noQueuedResponse }
        let next = queue.removeFirst()
        let resp = HTTPURLResponse(url: next.url, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        return (next.data, resp)
    }
}

/// Records the URL it was asked to open; never touches NSWorkspace.
final class FakeBrowserOpener: BrowserOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    func open(_ url: URL) { lock.lock(); _opened.append(url); lock.unlock() }
    var opened: [URL] { lock.lock(); defer { lock.unlock() }; return _opened }
}

/// Returns a canned loopback result instead of binding a real socket.
struct FakeLoopbackCapture: LoopbackCapturing {
    let port: Int
    let result: LoopbackResult
    func boundPort() -> Int { port }
    func awaitRedirect() async throws -> LoopbackResult { result }
    func stop() {}
}

// ---- self-test ----

@Test func fakeHTTPClientReplaysAndRecords() async throws {
    let http = FakeHTTPClient()
    await http.enqueueJSON(#"{"ok":true}"#)
    var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    req.httpMethod = "POST"
    let (data, resp) = try await http.send(req)
    #expect(resp.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
    #expect(await http.recordedRequests.count == 1)
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter fakeHTTPClientReplaysAndRecords
```

Expected: failure — no test target / `BrowserOpening`, `LoopbackCapturing`, `LoopbackResult` undefined (`error: no such module` for the test target, or `cannot find type` once the target resolves).

- [ ] **Step 3: Minimal impl** — add the test target to `SenaniApp/Package.swift`. Edit the `targets:` array to append:

```swift
        .testTarget(
            name: "SenaniAppTests",
            dependencies: [
                "SenaniApp",
                .product(name: "SenaniGmail", package: "SenaniGmail"),
            ]
        ),
```

> Keep `// swift-tools-version: 5.9` and the executable target unchanged. The test target depends on the `SenaniApp` executable target (allowed for SwiftPM executables) and on `SenaniGmail` for `HTTPClient`/`TokenStore`/`OAuthToken`.

The protocols `BrowserOpening`, `LoopbackCapturing`, and `LoopbackResult` are defined in Tasks 3 and 4. To make Task 1's self-test compile *now* without forward-declaring app types in the test, this task ALSO creates the minimal protocol stubs they reference. Create `SenaniApp/Sources/SenaniApp/Gmail/BrowserOpening.swift` and `SenaniApp/Sources/SenaniApp/Gmail/LoopbackCapture.swift` with **protocol-only** content (full impls land in Tasks 3/4):

`BrowserOpening.swift`:
```swift
import Foundation

/// Opens an OAuth consent URL in the user's default browser. Behind a protocol
/// so the OAuth flow is unit-testable without launching a real browser.
public protocol BrowserOpening: Sendable {
    func open(_ url: URL)
}
```

`LoopbackCapture.swift`:
```swift
import Foundation

/// The redirect captured by the transient loopback listener.
public struct LoopbackResult: Sendable, Equatable {
    public let code: String?
    public let state: String?
    public let error: String?
    public init(code: String?, state: String?, error: String?) {
        self.code = code; self.state = state; self.error = error
    }
}

/// A transient localhost HTTP listener that captures the OAuth redirect.
/// Behind a protocol so the flow is unit-testable without binding a socket.
public protocol LoopbackCapturing: Sendable {
    func boundPort() -> Int
    func awaitRedirect() async throws -> LoopbackResult
    func stop()
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter fakeHTTPClientReplaysAndRecords
```

Expected: the self-test passes; package builds with the new test target.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: add test target + OAuth test doubles and protocol seams"
```

(Append the standard trailer.)

---

## Task 2 — `GmailOAuthConfig`: resolve the client ID (resolves the §5 OAuth open pin)

The Google OAuth **desktop** client ID is a build-time secret the human supplies; it is **never hard-coded or committed**. Resolution order (first hit wins):
1. **Environment variable** `SENANI_GMAIL_CLIENT_ID` (dev / CI).
2. **`Info.plist`** key `SenaniGmailClientID` (release builds — set in the app's Info.plist, which is per-build and not a source secret).
3. **Gitignored config file** `~/Library/Application Support/Senani/oauth.plist` (or `<app>/Config/oauth.plist` for dev), a plist with key `SenaniGmailClientID`.

If none resolve, `GmailOAuthConfig.clientID()` throws `GmailOAuthConfigError.missingClientID` so the UI can show a clear "set up your client ID" message rather than launching a broken consent flow.

> **Human action (document in the file's doc comment):** create a Google Cloud OAuth 2.0 **Desktop app** client, then provide the ID via one of the three sources above. Add `Config/oauth.plist` and any `*.client_secret*.json` to `.gitignore`. The desktop flow uses PKCE and needs **no client secret**.

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/Gmail/GmailOAuthConfig.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/GmailOAuthConfigTests.swift`
- Edit: `SenaniApp/.gitignore` (create if absent) — add `Config/oauth.plist` and `*.client_secret*.json`

**Steps:**

- [ ] **Step 1: Write FAILING tests** — `SenaniApp/Tests/SenaniAppTests/GmailOAuthConfigTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp

@Test func scopesIncludeReadModifyComposeAndIdentity() {
    let s = GmailOAuthConfig.scopes
    #expect(s.contains("https://www.googleapis.com/auth/gmail.readonly"))
    #expect(s.contains("https://www.googleapis.com/auth/gmail.modify"))
    #expect(s.contains("https://www.googleapis.com/auth/gmail.compose"))
    #expect(s.contains("openid"))
    #expect(s.contains("email"))
}

@Test func resolvesClientIDFromEnvironmentFirst() throws {
    let env = ["SENANI_GMAIL_CLIENT_ID": "ENV.apps.googleusercontent.com"]
    let id = try GmailOAuthConfig.clientID(
        environment: env,
        infoPlistValue: "PLIST.apps.googleusercontent.com",
        fileValue: { "FILE.apps.googleusercontent.com" })
    #expect(id == "ENV.apps.googleusercontent.com")
}

@Test func fallsBackToInfoPlistThenFile() throws {
    let fromPlist = try GmailOAuthConfig.clientID(
        environment: [:], infoPlistValue: "PLIST.apps.googleusercontent.com", fileValue: { nil })
    #expect(fromPlist == "PLIST.apps.googleusercontent.com")
    let fromFile = try GmailOAuthConfig.clientID(
        environment: [:], infoPlistValue: nil, fileValue: { "FILE.apps.googleusercontent.com" })
    #expect(fromFile == "FILE.apps.googleusercontent.com")
}

@Test func throwsWhenNoClientIDAnywhere() {
    #expect(throws: GmailOAuthConfigError.self) {
        _ = try GmailOAuthConfig.clientID(environment: [:], infoPlistValue: nil, fileValue: { nil })
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter GmailOAuthConfigTests
```

Expected: failure — `GmailOAuthConfig` / `GmailOAuthConfigError` undefined.

- [ ] **Step 3: Minimal impl** — `SenaniApp/Sources/SenaniApp/Gmail/GmailOAuthConfig.swift`:

```swift
import Foundation

public enum GmailOAuthConfigError: Error, Equatable {
    case missingClientID
}

/// Resolves the Google OAuth *desktop* client ID and the Gmail scopes.
///
/// The client ID is a build-time value the human supplies; it is NEVER committed.
/// Resolution order: env `SENANI_GMAIL_CLIENT_ID` → Info.plist `SenaniGmailClientID`
/// → gitignored `~/Library/Application Support/Senani/oauth.plist` (key `SenaniGmailClientID`).
///
/// Human setup: create a Google Cloud OAuth 2.0 *Desktop app* client and provide
/// the ID via one of those sources. The desktop/PKCE flow needs NO client secret.
public enum GmailOAuthConfig {
    public static let scopes: [String] = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
        "openid",
        "email",
    ]

    /// Testable resolver: callers inject the three sources.
    public static func clientID(
        environment: [String: String],
        infoPlistValue: String?,
        fileValue: () -> String?
    ) throws -> String {
        if let env = environment["SENANI_GMAIL_CLIENT_ID"], !env.isEmpty { return env }
        if let plist = infoPlistValue, !plist.isEmpty { return plist }
        if let file = fileValue(), !file.isEmpty { return file }
        throw GmailOAuthConfigError.missingClientID
    }

    /// Production resolver: reads the real environment, bundle Info.plist, and config file.
    public static func clientID() throws -> String {
        try clientID(
            environment: ProcessInfo.processInfo.environment,
            infoPlistValue: Bundle.main.object(forInfoDictionaryKey: "SenaniGmailClientID") as? String,
            fileValue: { readConfigFileClientID() })
    }

    private static func readConfigFileClientID() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = appSupport?.appendingPathComponent("Senani/oauth.plist")
        guard let url, let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["SenaniGmailClientID"] as? String
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter GmailOAuthConfigTests
```

Expected: all 4 tests pass.

- [ ] **Step 5: Add `.gitignore` entries** — ensure `SenaniApp/.gitignore` contains:

```
Config/oauth.plist
*.client_secret*.json
```

(Create the file if it doesn't exist; append if it does.)

- [ ] **Step 6: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: GmailOAuthConfig resolves desktop client ID (env/plist/file) + scopes"
```

(Append the standard trailer.)

---

## Task 3 — `NSWorkspaceBrowserOpener` (real browser opener)

`BrowserOpening` already exists from Task 1. Add the live implementation. There is no unit test for the real opener (it would launch a browser); it is exercised only via the manual integration path (Task 9). The fake (`FakeBrowserOpener`) covers the orchestration tests.

**Files:**
- Edit: `SenaniApp/Sources/SenaniApp/Gmail/BrowserOpening.swift`

**Steps:**

- [ ] **Step 1: Write a FAILING compile-smoke test** — add to a new `SenaniApp/Tests/SenaniAppTests/BrowserOpenerSmokeTests.swift`:

```swift
import Testing
@testable import SenaniApp

@Test func liveBrowserOpenerConformsToProtocol() {
    let _: any BrowserOpening = NSWorkspaceBrowserOpener()
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter liveBrowserOpenerConformsToProtocol
```

Expected: failure — `NSWorkspaceBrowserOpener` undefined.

- [ ] **Step 3: Minimal impl** — append to `SenaniApp/Sources/SenaniApp/Gmail/BrowserOpening.swift`:

```swift
#if canImport(AppKit)
import AppKit

/// Live opener: hands the consent URL to the default browser via NSWorkspace.
public struct NSWorkspaceBrowserOpener: BrowserOpening {
    public init() {}
    public func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
#endif
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter liveBrowserOpenerConformsToProtocol
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: NSWorkspaceBrowserOpener live browser opener"
```

(Append the standard trailer.)

---

## Task 4 — `NWLoopbackListener` + redirect parsing (transient localhost capture)

`LoopbackCapturing`/`LoopbackResult` exist from Task 1. This task adds (a) a **pure, unit-tested** redirect-query parser and (b) the live `NWLoopbackListener` (an `NWListener` on `127.0.0.1:0` that reads one HTTP request line, extracts the query, replies with a small "you can close this tab" page, then yields the result). Only the parser is unit-tested; the socket listener is exercised manually (Task 9).

**Files:**
- Edit: `SenaniApp/Sources/SenaniApp/Gmail/LoopbackCapture.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/LoopbackRedirectParsingTests.swift`

**Steps:**

- [ ] **Step 1: Write FAILING parser tests** — `SenaniApp/Tests/SenaniAppTests/LoopbackRedirectParsingTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp

@Test func parsesCodeAndStateFromRequestLine() {
    let line = "GET /oauth2redirect?code=AUTH123&state=STATE456 HTTP/1.1"
    let result = LoopbackRedirectParser.parse(requestLine: line)
    #expect(result.code == "AUTH123")
    #expect(result.state == "STATE456")
    #expect(result.error == nil)
}

@Test func parsesErrorWhenUserDenies() {
    let line = "GET /oauth2redirect?error=access_denied&state=STATE456 HTTP/1.1"
    let result = LoopbackRedirectParser.parse(requestLine: line)
    #expect(result.error == "access_denied")
    #expect(result.code == nil)
}

@Test func percentDecodesQueryValues() {
    let line = "GET /oauth2redirect?code=a%2Fb%2Bc&state=x HTTP/1.1"
    let result = LoopbackRedirectParser.parse(requestLine: line)
    #expect(result.code == "a/b+c")
}

@Test func missingQueryYieldsAllNil() {
    let result = LoopbackRedirectParser.parse(requestLine: "GET / HTTP/1.1")
    #expect(result.code == nil)
    #expect(result.state == nil)
    #expect(result.error == nil)
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter LoopbackRedirectParsingTests
```

Expected: failure — `LoopbackRedirectParser` undefined.

- [ ] **Step 3: Minimal impl** — append to `SenaniApp/Sources/SenaniApp/Gmail/LoopbackCapture.swift`:

```swift
/// Pure parser: turns the first HTTP request line of the captured redirect into a LoopbackResult.
public enum LoopbackRedirectParser {
    public static func parse(requestLine: String) -> LoopbackResult {
        // requestLine: "GET /oauth2redirect?code=...&state=... HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return LoopbackResult(code: nil, state: nil, error: nil) }
        let path = String(parts[1])
        guard let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
            return LoopbackResult(code: nil, state: nil, error: nil)
        }
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        return LoopbackResult(code: items["code"] ?? nil, state: items["state"] ?? nil, error: items["error"] ?? nil)
    }
}

#if canImport(Network)
import Network

/// Live capture: binds 127.0.0.1:0, reads one HTTP request, parses the redirect,
/// replies with a tiny close-tab page, then yields the result. macOS 14+.
public final class NWLoopbackListener: LoopbackCapturing, @unchecked Sendable {
    private let listener: NWListener
    private let port: Int

    public init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: .any)   // OS picks a free port
        self.listener = l
        l.start(queue: .global())
        // Wait briefly for the port assignment.
        var assigned = 0
        for _ in 0..<100 {
            if let p = l.port?.rawValue { assigned = Int(p); break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        self.port = assigned
    }

    public func boundPort() -> Int { port }

    public func awaitRedirect() async throws -> LoopbackResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LoopbackResult, Error>) in
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                    let result = LoopbackRedirectParser.parse(requestLine: firstLine)
                    let html = "<html><body>You can close this tab and return to Senani.</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    cont.resume(returning: result)
                }
            }
        }
    }

    public func stop() { listener.cancel() }
}
#endif
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter LoopbackRedirectParsingTests
```

Expected: all 4 parser tests pass; the `NWLoopbackListener` compiles (not exercised by unit tests).

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: loopback redirect parser + NWListener capture seam"
```

(Append the standard trailer.)

---

## Task 5 — `GmailOAuthFlow` + `GmailAccountInfo`: PKCE → consent URL → capture → exchange → email

The orchestrator. One `connect()` call: make `PKCE.random()` + a random `state`, build the consent URL via `GmailAuth.authorizationURL`, open the browser, `awaitRedirect()`, verify `state` and require `code`, call `GmailAuth.authenticate(code:redirectURI:verifier:)` (which persists the token), then fetch the account email via `GmailAccountInfo`. The flow holds a `GmailAuth` actor (injected — the composition root builds it per §4) plus the `BrowserOpening`/`LoopbackCapturing` factory and the `HTTPClient` for userinfo.

> **Why `GmailAuth.authenticate` and not a hand-rolled exchange:** `GmailAuth` already does the token exchange + `store.save` and is frozen/tested. The flow reuses it verbatim. The flow's only extra HTTP call is the userinfo GET (account email), which `SenaniGmail` does not provide.

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/Gmail/GmailAccountInfo.swift`
- Create: `SenaniApp/Sources/SenaniApp/Gmail/GmailOAuthFlow.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/PKCERoundTripTests.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/GmailOAuthFlowAuthURLTests.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/GmailOAuthFlowExchangeTests.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/GmailAuthRefreshTests.swift`

**Steps:**

- [ ] **Step 1: Write FAILING PKCE round-trip test** — `SenaniApp/Tests/SenaniAppTests/PKCERoundTripTests.swift`:

```swift
import Testing
import Foundation
import SenaniGmail
@testable import SenaniApp

@Test func pkceVerifierAndChallengeRoundTrip() {
    let pkce = PKCE.random()
    #expect(pkce.verifier.count == 64)
    // challenge is base64url(SHA256(verifier)): url-safe, unpadded, deterministic for a fixed verifier
    #expect(!pkce.challenge.contains("="))
    #expect(!pkce.challenge.contains("+"))
    #expect(!pkce.challenge.contains("/"))
    #expect(PKCE(verifier: pkce.verifier).challenge == pkce.challenge)   // deterministic round-trip
    #expect(PKCE.random().verifier != pkce.verifier)                     // random differs
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter pkceVerifierAndChallengeRoundTrip
```

Expected: this test PASSES immediately (it exercises only the frozen `PKCE`). This is the one task whose first test is a green characterization of the upstream API — keep it as a guard. Proceed to Step 3 to add the failing flow tests.

- [ ] **Step 3: Write FAILING auth-URL test** — `SenaniApp/Tests/SenaniAppTests/GmailOAuthFlowAuthURLTests.swift`:

```swift
import Testing
import Foundation
import SenaniGmail
@testable import SenaniApp

@Test func consentURLContainsScopesChallengeAndLoopbackRedirect() throws {
    let pkce = PKCE(verifier: "verifier-123")
    let url = GmailOAuthFlow.consentURL(
        clientID: "CID.apps.googleusercontent.com",
        port: 49152,
        pkce: pkce,
        state: "STATE")
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(comps.host == "accounts.google.com")
    let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(q["client_id"] == "CID.apps.googleusercontent.com")
    #expect(q["redirect_uri"] == "http://127.0.0.1:49152/oauth2redirect")
    #expect(q["code_challenge"] == pkce.challenge)
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["state"] == "STATE")
    #expect(q["access_type"] == "offline")
    let scope = q["scope"] ?? ""
    #expect(scope.contains("gmail.readonly"))
    #expect(scope.contains("gmail.modify"))
    #expect(scope.contains("gmail.compose"))
}
```

- [ ] **Step 4: Write FAILING exchange test** — `SenaniApp/Tests/SenaniAppTests/GmailOAuthFlowExchangeTests.swift`:

```swift
import Testing
import Foundation
import SenaniGmail
@testable import SenaniApp

@Test func connectExchangesCodeStoresTokenAndReturnsEmail() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    // 1) token-exchange response (consumed by GmailAuth.authenticate)
    await http.enqueueJSON(
        #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#,
        url: URL(string: "https://oauth2.googleapis.com/token")!)
    // 2) userinfo response (consumed by GmailAccountInfo)
    await http.enqueueJSON(
        #"{"email":"ramesh@quantana.in","email_verified":true}"#,
        url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)

    let auth = GmailAuth(clientID: "CID", http: http, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
    let browser = FakeBrowserOpener()
    let capture = FakeLoopbackCapture(
        port: 49152,
        result: LoopbackResult(code: "AUTHCODE", state: "EXPECTED_STATE", error: nil))

    let flow = GmailOAuthFlow(
        auth: auth,
        clientID: "CID",
        http: http,
        browser: browser,
        makeLoopback: { capture },
        makeState: { "EXPECTED_STATE" })

    let email = try await flow.connect()

    #expect(email == "ramesh@quantana.in")
    #expect(browser.opened.count == 1)                       // consent URL was opened
    #expect(browser.opened.first?.host == "accounts.google.com")
    let stored = try await store.load()
    #expect(stored?.accessToken == "AT")                     // token persisted via GmailAuth
    #expect(stored?.refreshToken == "RT")
}

@Test func connectThrowsOnStateMismatch() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let capture = FakeLoopbackCapture(
        port: 49152, result: LoopbackResult(code: "C", state: "WRONG", error: nil))
    let flow = GmailOAuthFlow(
        auth: auth, clientID: "CID", http: http, browser: FakeBrowserOpener(),
        makeLoopback: { capture }, makeState: { "EXPECTED" })
    await #expect(throws: GmailOAuthError.self) { _ = try await flow.connect() }
    #expect(try await store.load() == nil)                   // nothing persisted
}

@Test func connectThrowsWhenUserDenies() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let capture = FakeLoopbackCapture(
        port: 49152, result: LoopbackResult(code: nil, state: "S", error: "access_denied"))
    let flow = GmailOAuthFlow(
        auth: auth, clientID: "CID", http: http, browser: FakeBrowserOpener(),
        makeLoopback: { capture }, makeState: { "S" })
    await #expect(throws: GmailOAuthError.self) { _ = try await flow.connect() }
}
```

- [ ] **Step 5: Write FAILING refresh test** — `SenaniApp/Tests/SenaniAppTests/GmailAuthRefreshTests.swift`:

```swift
import Testing
import Foundation
import SenaniGmail
@testable import SenaniApp

@Test func validAccessTokenRefreshesWhenExpired() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "old", refreshToken: "RT",
                                    expiresAt: now.addingTimeInterval(10)))   // expires within skew
    let http = FakeHTTPClient()
    await http.enqueueJSON(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#,
                           url: URL(string: "https://oauth2.googleapis.com/token")!)
    let auth = GmailAuth(clientID: "CID", http: http, store: store, now: { now })

    let token = try await auth.validAccessToken()

    #expect(token == "new")
    let stored = try await store.load()
    #expect(stored?.accessToken == "new")
    #expect(stored?.refreshToken == "RT")                    // preserved when response omits it
}

@Test func validAccessTokenSkipsRefreshWhenFresh() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "good", refreshToken: "RT",
                                    expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store, now: { now })
    #expect(try await auth.validAccessToken() == "good")
    #expect(await http.recordedRequests.isEmpty)             // no network when fresh
}
```

- [ ] **Step 6: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter GmailOAuthFlow
```

Expected: compile failure — `GmailOAuthFlow`, `GmailOAuthError`, `GmailAccountInfo` undefined. (The refresh tests in `GmailAuthRefreshTests` would pass once they compile, but the target won't build until the flow types exist — so the whole test target fails to build first.)

- [ ] **Step 7: Implement `GmailAccountInfo`** — `SenaniApp/Sources/SenaniApp/Gmail/GmailAccountInfo.swift`:

```swift
import Foundation
import SenaniGmail

/// Fetches the connected account's email from Google's userinfo endpoint,
/// using a fresh access token from the GmailAuth actor. Behind HTTPClient for tests.
public struct GmailAccountInfo: Sendable {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding

    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding) {
        self.http = http
        self.tokenProvider = tokenProvider
    }

    public func fetchEmail() async throws -> String {
        let token = try await tokenProvider.validAccessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(request)
        guard response.statusCode < 300 else {
            throw HTTPClientError.unexpectedStatus(response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let info = try JSONDecoder().decode(UserInfo.self, from: data)
        return info.email
    }

    private struct UserInfo: Decodable { let email: String }
}
```

- [ ] **Step 8: Implement `GmailOAuthFlow`** — `SenaniApp/Sources/SenaniApp/Gmail/GmailOAuthFlow.swift`:

```swift
import Foundation
import SenaniGmail

public enum GmailOAuthError: Error, Equatable {
    case stateMismatch
    case userDenied(String)
    case missingCode
}

/// Orchestrates one Gmail OAuth desktop/loopback consent round-trip.
///
/// The composition root constructs the `GmailAuth` actor (per APP-PLANS-RECONCILIATION §4)
/// and hands it to this flow; the flow never builds a TokenStore or reads the Keychain.
public struct GmailOAuthFlow: Sendable {
    private let auth: GmailAuth
    private let clientID: String
    private let http: any HTTPClient
    private let browser: any BrowserOpening
    private let makeLoopback: @Sendable () throws -> any LoopbackCapturing
    private let makeState: @Sendable () -> String

    public init(
        auth: GmailAuth,
        clientID: String,
        http: any HTTPClient,
        browser: any BrowserOpening,
        makeLoopback: @escaping @Sendable () throws -> any LoopbackCapturing,
        makeState: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.auth = auth
        self.clientID = clientID
        self.http = http
        self.browser = browser
        self.makeLoopback = makeLoopback
        self.makeState = makeState
    }

    /// Pure consent-URL builder (unit-tested independently).
    public static func consentURL(clientID: String, port: Int, pkce: PKCE, state: String) -> URL {
        GmailAuth.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI(port: port),
            scopes: GmailOAuthConfig.scopes,
            pkce: pkce,
            state: state)
    }

    public static func redirectURI(port: Int) -> String { "http://127.0.0.1:\(port)/oauth2redirect" }

    /// Runs the full flow and returns the connected account email. Persists the token via GmailAuth.
    public func connect() async throws -> String {
        let pkce = PKCE.random()
        let state = makeState()
        let loopback = try makeLoopback()
        defer { loopback.stop() }
        let port = loopback.boundPort()
        let redirectURI = Self.redirectURI(port: port)

        let url = GmailAuth.authorizationURL(
            clientID: clientID, redirectURI: redirectURI,
            scopes: GmailOAuthConfig.scopes, pkce: pkce, state: state)
        browser.open(url)

        let redirect = try await loopback.awaitRedirect()
        if let error = redirect.error { throw GmailOAuthError.userDenied(error) }
        guard redirect.state == state else { throw GmailOAuthError.stateMismatch }
        guard let code = redirect.code else { throw GmailOAuthError.missingCode }

        try await auth.authenticate(code: code, redirectURI: redirectURI, verifier: pkce.verifier)

        let info = GmailAccountInfo(http: http, tokenProvider: auth)
        return try await info.fetchEmail()
    }
}
```

- [ ] **Step 9: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter "PKCERoundTripTests OR GmailOAuthFlow OR GmailAuthRefreshTests"
```

(If the harness rejects the `OR` filter form, run `swift test` to exercise everything; the filter is a convenience only.)

Expected: all tests pass — PKCE round-trip, consent-URL scopes+challenge+loopback redirect, exchange-stores-token-and-returns-email, state-mismatch throws + persists nothing, user-denied throws, refresh-when-expired, skip-when-fresh.

- [ ] **Step 10: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: GmailOAuthFlow loopback consent + token exchange + account email"
```

(Append the standard trailer.)

---

## Task 6 — `GmailAccount`: `@MainActor @Observable` connection state for the composition root

A single observable object the composition root owns and screens read. It holds the connection state, runs the flow on `connect()`, and clears the token on `disconnect()`. On launch it reflects whether a token already exists (so a returning user skips onboarding).

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/Gmail/GmailAccount.swift`
- Create: `SenaniApp/Tests/SenaniAppTests/GmailAccountTests.swift`

**Steps:**

- [ ] **Step 1: Write FAILING tests** — `SenaniApp/Tests/SenaniAppTests/GmailAccountTests.swift`:

```swift
import Testing
import Foundation
import SenaniGmail
@testable import SenaniApp

@MainActor
@Test func connectTransitionsToConnectedWithEmail() async throws {
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient()
    await http.enqueueJSON(
        #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#,
        url: URL(string: "https://oauth2.googleapis.com/token")!)
    await http.enqueueJSON(
        #"{"email":"ramesh@quantana.in"}"#,
        url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
    let auth = GmailAuth(clientID: "CID", http: http, store: store, now: { Date(timeIntervalSince1970: 1_000_000) })
    let capture = FakeLoopbackCapture(port: 49152, result: LoopbackResult(code: "C", state: "S", error: nil))
    let flow = GmailOAuthFlow(auth: auth, clientID: "CID", http: http, browser: FakeBrowserOpener(),
                              makeLoopback: { capture }, makeState: { "S" })

    let account = GmailAccount(store: store, flow: flow)
    #expect(account.state == .disconnected)

    await account.connect()

    #expect(account.state == .connected(email: "ramesh@quantana.in"))
}

@MainActor
@Test func disconnectClearsTokenAndState() async throws {
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "AT", refreshToken: "RT",
                                    expiresAt: Date(timeIntervalSince1970: 9_999_999_999)))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let flow = GmailOAuthFlow(auth: auth, clientID: "CID", http: http, browser: FakeBrowserOpener(),
                              makeLoopback: { FakeLoopbackCapture(port: 1, result: LoopbackResult(code: nil, state: nil, error: nil)) },
                              makeState: { "S" })
    let account = GmailAccount(store: store, flow: flow)

    await account.disconnect()

    #expect(account.state == .disconnected)
    #expect(try await store.load() == nil)
}

@MainActor
@Test func refreshFromStoreReflectsExistingToken() async throws {
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "AT", refreshToken: "RT",
                                    expiresAt: Date(timeIntervalSince1970: 9_999_999_999)))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CID", http: http, store: store)
    let flow = GmailOAuthFlow(auth: auth, clientID: "CID", http: http, browser: FakeBrowserOpener(),
                              makeLoopback: { FakeLoopbackCapture(port: 1, result: LoopbackResult(code: nil, state: nil, error: nil)) })
    let account = GmailAccount(store: store, flow: flow)

    await account.refreshFromStore()

    #expect(account.isConnected)   // a token exists, so the user is considered connected
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter GmailAccountTests
```

Expected: failure — `GmailAccount` undefined.

- [ ] **Step 3: Minimal impl** — `SenaniApp/Sources/SenaniApp/Gmail/GmailAccount.swift`:

```swift
import Foundation
import Observation
import SenaniGmail

/// Connection state for the Gmail account, owned by the composition root and
/// read by onboarding + Settings. The only place the app drives the OAuth flow.
@MainActor
@Observable
public final class GmailAccount {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(email: String)
        case failed(message: String)
    }

    public private(set) var state: State = .disconnected

    private let store: any TokenStore
    private let flow: GmailOAuthFlow

    public init(store: any TokenStore, flow: GmailOAuthFlow) {
        self.store = store
        self.flow = flow
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Reflects whether a token already exists (returning user skips onboarding).
    /// Email is hydrated lazily; if absent we still mark connected with a placeholder
    /// so the UI doesn't force re-consent. A later sync can refresh the email.
    public func refreshFromStore() async {
        if (try? await store.load()) != nil {
            if case .connected = state {} else { state = .connected(email: "") }
        } else {
            state = .disconnected
        }
    }

    public func connect() async {
        state = .connecting
        do {
            let email = try await flow.connect()
            state = .connected(email: email)
        } catch {
            state = .failed(message: Self.describe(error))
        }
    }

    public func disconnect() async {
        try? await store.clear()
        state = .disconnected
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case GmailOAuthError.stateMismatch: return "Sign-in could not be verified. Please try again."
        case GmailOAuthError.userDenied: return "Access was not granted."
        case GmailOAuthError.missingCode: return "No authorization code was returned."
        case GmailAuthError.notAuthenticated: return "Google did not return a refresh token. Please try again and grant offline access."
        default: return "Could not connect to Gmail: \(error)"
        }
    }
}
```

> `refreshFromStore` marks a returning user connected with an empty email placeholder so onboarding is skipped without a network call; the account email is re-hydrated by the first `GmailAccountInfo.fetchEmail()` the app makes (e.g. on first sync — owned by the sync plan). The test asserts `isConnected`, not a specific email.

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter GmailAccountTests
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: GmailAccount observable connection state (connect/disconnect/refresh)"
```

(Append the standard trailer.)

---

## Task 7 — `ConnectAccountView` + wire into `AppState` (composition root) and first-run gating

Extend the scaffold's `AppState` (today's composition root) to build the live `GmailAuth` + `GmailAccount` per §4, and show `ConnectAccountView` until connected. No screen builds a `TokenStore` or `GmailAuth`.

**Files:**
- Edit: `SenaniApp/Sources/SenaniApp/SenaniApp.swift` (extend `AppState`; gate the root view)
- Create: `SenaniApp/Sources/SenaniApp/UI/ConnectAccountView.swift`

**Steps:**

- [ ] **Step 1: Write a FAILING composition test** — `SenaniApp/Tests/SenaniAppTests/AppStateGmailWiringTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniStore

@MainActor
@Test func appStateExposesGmailAccount() throws {
    let db = try SenaniDatabase.inMemory()
    let state = AppState(database: db)
    // The composition root owns a GmailAccount; screens read it (no screen builds GmailAuth).
    #expect(state.gmailAccount.state == .disconnected)
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter appStateExposesGmailAccount
```

Expected: failure — `AppState` has no `gmailAccount`.

- [ ] **Step 3: Implement** — edit `SenaniApp/Sources/SenaniApp/SenaniApp.swift`. Extend `AppState` to build the Gmail object graph in `init` and expose `gmailAccount`:

Replace the `AppState` class body with:

```swift
@Observable
final class AppState {
    let database: SenaniDatabase
    let messageStore: MessageStore
    let ruleStore: RuleStore

    // Gmail wiring (composition root owns GmailAuth + GmailAccount; screens receive them).
    // TODO(app-shell): fold gmailAuth/gmailAccount into AppEnvironment.live()/.preview().
    let gmailAccount: GmailAccount

    var selectedSidebarItem: NavigationItem? = .inbox

    init(database: SenaniDatabase) {
        self.database = database
        self.messageStore = MessageStore(database: database)
        self.ruleStore = RuleStore(database: database)

        let store: any TokenStore = KeychainTokenStore()
        let http: any HTTPClient = URLSessionHTTPClient()
        let clientID = (try? GmailOAuthConfig.clientID()) ?? ""
        let auth = GmailAuth(clientID: clientID, http: http, store: store)
        let flow = GmailOAuthFlow(
            auth: auth,
            clientID: clientID,
            http: http,
            browser: NSWorkspaceBrowserOpener(),
            makeLoopback: { try NWLoopbackListener() })
        self.gmailAccount = GmailAccount(store: store, flow: flow)
    }

    /// In-memory composition for previews/UI tests: no Keychain, no network, no browser.
    static func preview() -> AppState {
        let db = try! SenaniDatabase.inMemory()
        return AppState(database: db)
    }
}
```

Add the required imports at the top of the file (alongside the existing ones):

```swift
import SenaniGmail
```

Update the `body` of `SenaniApp` to gate on connection state and to hydrate the account on appear:

```swift
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 1000, minHeight: 600)
                .task { await appState.gmailAccount.refreshFromStore() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
```

Add a `RootView` (in the same file or `UI/`) that shows onboarding until connected:

```swift
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.gmailAccount.isConnected {
            MainNavigationView()
        } else {
            ConnectAccountView()
        }
    }
}
```

> `clientID` defaulting to `""` keeps the app launchable even before the human supplies a client ID; `ConnectAccountView` (next step) detects the empty client ID and shows setup guidance instead of launching a broken consent flow.

- [ ] **Step 4: Implement `ConnectAccountView`** — `SenaniApp/Sources/SenaniApp/UI/ConnectAccountView.swift`:

```swift
import SwiftUI

/// Onboarding: a single "Connect Gmail" call to action that drives the OAuth flow.
struct ConnectAccountView: View {
    @Environment(AppState.self) private var appState

    private var configured: Bool { (try? GmailOAuthConfig.clientID()).map { !$0.isEmpty } ?? false }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Connect your Gmail")
                .font(.largeTitle.weight(.semibold))
            Text("Senani runs entirely on your Mac. The only network hop is your own Google account.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            switch appState.gmailAccount.state {
            case .connecting:
                ProgressView("Waiting for Google sign-in in your browser…")
            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.callout)
                connectButton
            default:
                connectButton
            }

            if !configured {
                Text("No OAuth client ID configured. Set SENANI_GMAIL_CLIENT_ID, the SenaniGmailClientID Info.plist key, or ~/Library/Application Support/Senani/oauth.plist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectButton: some View {
        Button {
            Task { await appState.gmailAccount.connect() }
        } label: {
            Label("Connect Gmail", systemImage: "link")
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!configured)
    }
}

#Preview {
    ConnectAccountView().environment(AppState.preview())
}
```

- [ ] **Step 5: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter appStateExposesGmailAccount
```

Expected: pass. Also run a full build to confirm SwiftUI compiles:

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build
```

Expected: builds cleanly.

- [ ] **Step 6: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: wire GmailAccount into AppState + ConnectAccountView onboarding gate"
```

(Append the standard trailer.)

---

## Task 8 — `AccountSettingsView`: account row + Disconnect

A Settings control showing the connected email and a Disconnect button that calls `GmailAccount.disconnect()` (which clears the Keychain token via `TokenStore.clear()`).

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/AccountSettingsView.swift`

**Steps:**

- [ ] **Step 1: Write a FAILING build-smoke test** — add to `SenaniApp/Tests/SenaniAppTests/AppStateGmailWiringTests.swift`:

```swift
import SwiftUI

@MainActor
@Test func accountSettingsViewBuildsWithPreviewState() {
    let view = AccountSettingsView().environment(AppState.preview())
    _ = view.body   // forces the view tree to type-check/construct
}
```

- [ ] **Step 2: Run to fail**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter accountSettingsViewBuildsWithPreviewState
```

Expected: failure — `AccountSettingsView` undefined.

- [ ] **Step 3: Implement** — `SenaniApp/Sources/SenaniApp/UI/AccountSettingsView.swift`:

```swift
import SwiftUI

/// Settings: shows the connected Gmail account and a Disconnect control.
struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Gmail Account") {
                switch appState.gmailAccount.state {
                case .connected(let email):
                    LabeledContent("Connected") { Text(email.isEmpty ? "Your Google account" : email) }
                    Button("Disconnect", role: .destructive) {
                        Task { await appState.gmailAccount.disconnect() }
                    }
                case .connecting:
                    ProgressView("Connecting…")
                default:
                    Button("Connect Gmail") {
                        Task { await appState.gmailAccount.connect() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    AccountSettingsView().environment(AppState.preview())
}
```

- [ ] **Step 4: Run to pass**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test --filter accountSettingsViewBuildsWithPreviewState
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: AccountSettingsView with connected email + Disconnect"
```

(Append the standard trailer.)

---

## Task 9 — Env-gated manual integration test (real browser + loopback + live OAuth)

A REAL end-to-end test of the live `NWLoopbackListener` + `NSWorkspaceBrowserOpener` + `GmailAuth` against Google, SKIPPED unless a client ID is present so default `swift test` stays offline and green. Because it requires an interactive browser sign-in, it is gated and documented as manual.

**Files:**
- Create: `SenaniApp/Tests/SenaniAppTests/GmailOAuthIntegrationTests.swift`

**Required env var:** `SENANI_GMAIL_CLIENT_ID` (a real Google OAuth desktop client ID).

**Steps:**

- [ ] **Step 1: Write the gated test:**

```swift
import Testing
import Foundation
import SenaniGmail
@testable import SenaniApp

private var liveClientID: String? {
    let id = ProcessInfo.processInfo.environment["SENANI_GMAIL_CLIENT_ID"]
    return (id?.isEmpty == false) ? id : nil
}

@Test(.enabled(if: liveClientID != nil))
func liveConsentFlowAgainstRealGoogle() async throws {
    // MANUAL: opens a real browser; complete Google sign-in within the timeout.
    let clientID = try #require(liveClientID)
    let store = InMemoryTokenStore()
    let http = URLSessionHTTPClient()
    let auth = GmailAuth(clientID: clientID, http: http, store: store)
    let flow = GmailOAuthFlow(
        auth: auth, clientID: clientID, http: http,
        browser: NSWorkspaceBrowserOpener(),
        makeLoopback: { try NWLoopbackListener() })
    let email = try await flow.connect()      // real consent + exchange + userinfo
    #expect(email.contains("@"))
    #expect(try await store.load()?.refreshToken.isEmpty == false)
}
```

- [ ] **Step 2: Add a doc comment** explaining: the human must create a Google Cloud OAuth **Desktop** client, export `SENANI_GMAIL_CLIENT_ID`, run only this test, and complete the browser sign-in manually. Note the loopback listener binds an ephemeral `127.0.0.1` port and the redirect URI is derived from it.

- [ ] **Step 3: Run (offline, no env)**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test
```

Expected: the integration test is SKIPPED via `.enabled(if:)`; all unit tests pass.

- [ ] **Step 4: (Manual, when a client ID is available)**

```
SENANI_GMAIL_CLIENT_ID=... swift test --filter liveConsentFlowAgainstRealGoogle
```

Expected: a browser opens; after sign-in, the test passes against live Google.

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: env-gated manual live Gmail consent integration test"
```

(Append the standard trailer.)

---

## Task 10 — Final green run + public API review

**Files:** (review-only; fix visibility/imports as needed)

**Steps:**

- [ ] Confirm the app-tier types compile with appropriate access levels: `GmailOAuthConfig`/`GmailOAuthConfigError`, `BrowserOpening`/`NSWorkspaceBrowserOpener`, `LoopbackCapturing`/`LoopbackResult`/`LoopbackRedirectParser`/`NWLoopbackListener`, `GmailAccountInfo`, `GmailOAuthFlow`/`GmailOAuthError`, `GmailAccount`. (These are app-internal; `public` is not required since there's no downstream package — but the protocol seams may be `public` for clarity. Keep consistent.)
- [ ] Confirm NO frozen package was edited:

```
cd /Users/vishalkumar/Downloads/qmail && git status --porcelain Packages/SenaniGmail
```

Expected: empty output (no changes under `Packages/SenaniGmail`).

- [ ] Run the full suite + build:

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift test && swift build
```

Expected: all unit tests pass; integration test skipped; app builds.

- [ ] Commit (if any fixes):

```
cd /Users/vishalkumar/Downloads/qmail/SenaniApp && git add -A && git commit -m "SenaniApp: finalize Gmail OAuth + onboarding surface"
```

(Append the standard trailer.)

---

## Self-Review

- **Codes to the REAL `SenaniGmail` API (verified from source, not guessed).** `GmailAuth.init(clientID:http:store:now:)`, `GmailAuth.authorizationURL(clientID:redirectURI:scopes:pkce:state:)`, `GmailAuth.authenticate(code:redirectURI:verifier:)`, `validAccessToken()`, `PKCE.random()`/`PKCE(verifier:)`/`.challenge`, `TokenStore.save/load/clear`, `InMemoryTokenStore`, `KeychainTokenStore`, `OAuthToken`, `HTTPClient`/`HTTPClientError`/`URLSessionHTTPClient`, `AccessTokenProviding`, `GmailAuthError` — all match `Packages/SenaniGmail/Sources/SenaniGmail/{GmailAuth,Keychain,HTTPClient,GmailEndpoints,GmailSync}.swift`. No frozen package is edited (Task 10 verifies via `git status`).
- **Resolves the §5 OAuth client-ID open pin.** `GmailOAuthConfig` reads the desktop client ID from env → Info.plist → gitignored `oauth.plist`, throws `.missingClientID` when absent, documents that the human supplies it, and never hard-codes or commits a secret (`.gitignore` updated; PKCE/desktop flow needs no client secret). `ConnectAccountView` degrades gracefully (disabled button + setup guidance) when unconfigured.
- **Honors §3/§4 conventions.** The composition root (the scaffold's `AppState`, with a `// TODO(app-shell)` seam to fold into `AppEnvironment` later) constructs `GmailAuth` + `GmailOAuthFlow` + `GmailAccount`; screens (`ConnectAccountView`, `AccountSettingsView`) receive `GmailAccount` via `@Environment` and never build a `TokenStore`/`GmailAuth` or touch the Keychain. `AppState.preview()` uses `SenaniDatabase.inMemory()` so previews/UI tests need no Keychain/network/browser.
- **One auth path.** Token persistence and refresh flow entirely through the frozen `GmailAuth` + `TokenStore`; the flow reuses `GmailAuth.authenticate` rather than hand-rolling a second exchange. Sign-out is `TokenStore.clear()` via `GmailAccount.disconnect()`.
- **Tests use fakes only — no real network/browser/Keychain.** `InMemoryTokenStore`, a local `FakeHTTPClient` (canned token-exchange + userinfo JSON), `FakeBrowserOpener`, and `FakeLoopbackCapture`. The required test matrix is covered: PKCE verifier/challenge round-trip (`PKCERoundTripTests`), auth URL contains scopes + challenge + loopback redirect (`GmailOAuthFlowAuthURLTests`), code-exchange stores a token + returns email (`GmailOAuthFlowExchangeTests`), `validAccessToken` refreshes when expired + skips when fresh (`GmailAuthRefreshTests`), sign-out clears (`GmailAccountTests`), plus state-mismatch/user-denied negative paths and the pure `LoopbackRedirectParser`. The only live path is `GmailOAuthIntegrationTests`, gated by `.enabled(if:)` on `SENANI_GMAIL_CLIENT_ID`.
- **Toolchain matches the scaffold.** `SenaniApp/Package.swift` stays `swift-tools-version: 5.9`, macOS 14; a `SenaniAppTests` target is added (the executable had none). Swift Testing (`import Testing`). System frameworks only (`Network`, `AppKit`, `Foundation`).
- **TDD shape, bite-sized, no placeholders.** Every task: complete failing test → exact run-to-fail command + expected failure → complete minimal impl → run-to-pass → commit with the required trailer. All paths and commands are absolute/exact.
- **Open items flagged for the human:** (1) provision the Google OAuth **Desktop** client ID and supply it via one of the three config sources; (2) re-consent (not silent re-auth) is required if the refresh token is ever lost — `GmailAuth.authenticate` throws `.notAuthenticated` when Google omits `refresh_token`, which `authorizationURL`'s `access_type=offline` + `prompt=consent` avoids on first consent; (3) Calendar scope is added later by the Booking plan and may force re-consent; (4) the `AppEnvironment` composition root (app-shell plan) will later absorb the `gmailAuth`/`gmailAccount` wiring currently living on `AppState` (marked with `// TODO(app-shell)`).
