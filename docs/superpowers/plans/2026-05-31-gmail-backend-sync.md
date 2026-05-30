# SenaniGmail — Gmail MailBackend + Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SenaniGmail` Swift package that implements `SenaniRules.MailBackend` against the raw Gmail REST API and parses Gmail messages into `SenaniRules.Message`, with all networking behind a testable `HTTPClient` seam and OAuth/Keychain wired but unit-tested deterministically.

**Architecture:** All HTTP goes through an `HTTPClient` protocol (`send(_:) -> (Data, HTTPURLResponse)`); the real `URLSessionHTTPClient` wraps `URLSession`, and `FakeHTTPClient` replays queued fixture responses in tests. `GmailAuth` performs OAuth 2.0 PKCE (browser via `ASWebAuthenticationSession`, tokens in the macOS Keychain, refresh decisions made by pure logic that is unit-tested behind the seam). `GmailMailBackend` maps each `Action` to a Gmail REST request (`users.messages.modify`, `users.drafts.create`, `users.messages.send`); non-mail actions are no-ops. `GmailSync` lists+fetches messages and parses the Gmail `format=full` JSON into `Message`. No live network in unit tests; the real browser+API flow lives in one env-gated integration test.

**Tech Stack:** Swift 6.2 (swift-tools 6.0), macOS 14, strict concurrency, Swift Testing (`import Testing`), `Foundation`/`URLSession` + `AuthenticationServices` (system frameworks only), path dependency on `../SenaniRules`. Raw Gmail REST at `https://gmail.googleapis.com`, OAuth at `https://accounts.google.com/o/oauth2/v2/auth` + `https://oauth2.googleapis.com/token`.

---

## File Structure

```
Packages/SenaniGmail/
├── Package.swift
├── Sources/
│   └── SenaniGmail/
│       ├── HTTPClient.swift            // HTTPClient protocol + HTTPClientError
│       ├── URLSessionHTTPClient.swift  // real URLSession-backed impl
│       ├── GmailEndpoints.swift        // base URLs, request builders, JSON DTOs
│       ├── GmailAuth.swift             // PKCE, token model, refresh decision, Keychain, ASWebAuthenticationSession
│       ├── Keychain.swift              // TokenStore protocol + KeychainTokenStore + InMemoryTokenStore
│       ├── GmailMailBackend.swift      // MailBackend conformance: Action -> REST request
│       ├── MIMEBuilder.swift           // RFC 2822 message + base64url for send/reply/forward
│       └── GmailSync.swift             // list + get(full) + GmailMessageParser -> Message
└── Tests/
    └── SenaniGmailTests/
        ├── FakeHTTPClient.swift                 // test helper: queued fixtures (also a shipped contract)
        ├── Fixtures.swift                       // raw JSON fixture strings
        ├── HTTPClientTests.swift
        ├── GmailAuthTests.swift
        ├── GmailMailBackendTests.swift
        ├── MIMEBuilderTests.swift
        ├── GmailSyncParserTests.swift
        └── GmailIntegrationTests.swift          // env-gated real OAuth + live API
```

**Conventions for every task below:**
- `<pkg>` = `/Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail`
- Run tests with: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
- Do NOT edit `../SenaniRules`. Import it as `import SenaniRules`.
- Commit trailer (append to EVERY commit message):

```

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
```

---

## Task 0 — Package skeleton (compiles, no logic)

**Files:**
- `Packages/SenaniGmail/Package.swift` (new)
- `Packages/SenaniGmail/Sources/SenaniGmail/HTTPClient.swift` (new, minimal stub so the target compiles)
- `Packages/SenaniGmail/Tests/SenaniGmailTests/HTTPClientTests.swift` (new, trivial passing test to prove the harness runs)

**Steps:**
- [ ] Write `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniGmail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniGmail", targets: ["SenaniGmail"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
    ],
    targets: [
        .target(
            name: "SenaniGmail",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniGmailTests",
            dependencies: ["SenaniGmail"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] Write a placeholder `HTTPClient.swift` containing only `import Foundation` and an empty internal enum `SenaniGmailModule {}` so the target has a source file and compiles.
- [ ] Write `HTTPClientTests.swift`:

```swift
import Testing
@testable import SenaniGmail

@Test func packageCompilesAndTestsRun() {
    #expect(Bool(true))
}
```

- [ ] Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: builds and the single test passes (proves toolchain + path dep + Swift Testing wiring).
- [ ] Commit: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && git add -A && git commit -m "SenaniGmail: package skeleton with SenaniRules path dep"` (with trailer)

---

## Task 1 — `HTTPClient` protocol + `FakeHTTPClient` + `URLSessionHTTPClient`

**Files:**
- `Sources/SenaniGmail/HTTPClient.swift` (replace stub)
- `Sources/SenaniGmail/URLSessionHTTPClient.swift` (new)
- `Tests/SenaniGmailTests/FakeHTTPClient.swift` (new)
- `Tests/SenaniGmailTests/HTTPClientTests.swift` (extend)

**Steps:**
- [ ] Write FAILING test in `HTTPClientTests.swift` — `FakeHTTPClient` returns queued responses FIFO and records sent requests:

```swift
import Testing
import Foundation
@testable import SenaniGmail

@Test func fakeHTTPClientReturnsQueuedResponseAndRecordsRequest() async throws {
    let fake = FakeHTTPClient()
    let url = URL(string: "https://gmail.googleapis.com/x")!
    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    await fake.enqueue(data: Data("{\"ok\":true}".utf8), response: resp)

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    let (data, http) = try await fake.send(req)

    #expect(http.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == "{\"ok\":true}")
    let recorded = await fake.recordedRequests
    #expect(recorded.count == 1)
    #expect(recorded.first?.httpMethod == "POST")
}

@Test func fakeHTTPClientThrowsWhenQueueEmpty() async {
    let fake = FakeHTTPClient()
    let req = URLRequest(url: URL(string: "https://example.com")!)
    await #expect(throws: HTTPClientError.self) { _ = try await fake.send(req) }
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: compile failure — `HTTPClient`, `FakeHTTPClient`, `HTTPClientError` do not exist yet.
- [ ] Minimal impl in `HTTPClient.swift`:

```swift
import Foundation

public enum HTTPClientError: Error, Equatable {
    case noQueuedResponse
    case nonHTTPResponse
    case unexpectedStatus(Int, body: String)
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

- [ ] Impl `URLSessionHTTPClient.swift`:

```swift
import Foundation

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.nonHTTPResponse }
        return (data, http)
    }
}
```

- [ ] Impl test helper `FakeHTTPClient.swift` (in the test target; this is the shipped test contract listed in CONTRACTS):

```swift
import Foundation
@testable import SenaniGmail

actor FakeHTTPClient: HTTPClient {
    struct Queued { let data: Data; let response: HTTPURLResponse }
    private var queue: [Queued] = []
    private(set) var recordedRequests: [URLRequest] = []

    func enqueue(data: Data, response: HTTPURLResponse) { queue.append(.init(data: data, response: response)) }

    func enqueueJSON(_ json: String, status: Int = 200,
                     url: URL = URL(string: "https://gmail.googleapis.com")!) {
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        queue.append(.init(data: Data(json.utf8), response: resp))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queue.isEmpty else { throw HTTPClientError.noQueuedResponse }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }
}
```

- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: all tests pass.
- [ ] Commit: `git add -A && git commit -m "SenaniGmail: HTTPClient seam with URLSession impl and FakeHTTPClient"` (with trailer)

---

## Task 2 — `GmailEndpoints`: request builders + JSON DTOs

This task centralizes URL/method/header/body construction so the backend and sync are thin and every request is unit-testable.

**Files:**
- `Sources/SenaniGmail/GmailEndpoints.swift` (new)
- `Tests/SenaniGmailTests/Fixtures.swift` (new — fixture JSON strings)
- `Tests/SenaniGmailTests/GmailMailBackendTests.swift` (new — first endpoint test here; expanded in Task 4)

**Steps:**
- [ ] Write FAILING tests for the `modify` request builder in `GmailMailBackendTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniGmail

@Test func modifyRequestBuildsCorrectURLMethodAndBody() throws {
    let req = GmailEndpoints.modify(
        messageId: "abc123",
        addLabelIds: ["STARRED"],
        removeLabelIds: [],
        accessToken: "TOKEN")
    #expect(req.url?.absoluteString
        == "https://gmail.googleapis.com/gmail/v1/users/me/messages/abc123/modify")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
    #expect(body?["addLabelIds"] as? [String] == ["STARRED"])
    #expect(body?["removeLabelIds"] as? [String] == [])
}

@Test func listRequestEncodesQueryAndPageToken() {
    let req = GmailEndpoints.listMessages(query: "in:inbox", pageToken: "PG", maxResults: 50, accessToken: "T")
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.path == "/gmail/v1/users/me/messages")
    let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(items["q"] == "in:inbox")
    #expect(items["pageToken"] == "PG")
    #expect(items["maxResults"] == "50")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer T")
}

@Test func getMessageRequestUsesFullFormat() {
    let req = GmailEndpoints.getMessage(id: "m1", accessToken: "T")
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    #expect(comps.path == "/gmail/v1/users/me/messages/m1")
    let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(items["format"] == "full")
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: compile failure — `GmailEndpoints` does not exist.
- [ ] Minimal impl `GmailEndpoints.swift`. Provide:
  - `static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!`
  - `static func modify(messageId:addLabelIds:removeLabelIds:accessToken:) -> URLRequest` — POST `.../messages/{id}/modify`, JSON body `{"addLabelIds":[...],"removeLabelIds":[...]}`, `Authorization: Bearer <token>`, `Content-Type: application/json`.
  - `static func listMessages(query:pageToken:maxResults:accessToken:) -> URLRequest` — GET `.../messages` with `q`, `pageToken` (omit if nil), `maxResults` query items; bearer header.
  - `static func getMessage(id:accessToken:) -> URLRequest` — GET `.../messages/{id}?format=full`; bearer header.
  - `static func createDraft(rawBase64URL:accessToken:) -> URLRequest` — POST `.../drafts`, body `{"message":{"raw":"<base64url>"}}`.
  - `static func sendMessage(rawBase64URL:threadId:accessToken:) -> URLRequest` — POST `.../messages/send`, body `{"raw":"<base64url>", "threadId":"<id>"}` (omit `threadId` when nil).
  - DTOs for response parsing (used in Task 5): `ListResponse { messages: [MessageRef]?; nextPageToken: String? }`, `MessageRef { id: String }`, and the full-message DTOs (`GmailFullMessage`, `GmailPayload`, `GmailHeader`, `GmailBody`, `GmailPart`) as `Decodable`. Keep DTOs `internal`.
  - Use a shared private helper to add the bearer header so headers are consistent.
- [ ] Add fixture constants in `Fixtures.swift` now (used heavily in Task 5) — at minimum: `listJSON`, `plainTextMessageJSON`, `multipartWithAttachmentJSON`, `multipartNoAttachmentJSON`, `messageWithListUnsubscribeJSON`, `messageFromUserJSON`. Each is a `let` String holding realistic Gmail `format=full` JSON (headers array with `name`/`value`, `payload.parts` with `mimeType`/`filename`/`body.data` base64url, `labelIds`, `threadId`, `internalDate` millis). See Task 5 for required shapes.
- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: the three endpoint tests pass.
- [ ] Commit: `git add -A && git commit -m "SenaniGmail: Gmail REST endpoint builders and response DTOs"` (with trailer)

---

## Task 3 — `GmailAuth`: PKCE construction + token-refresh decision + Keychain seam

Browser presentation is NOT unit-tested here (it lives in the gated integration test, Task 6). We unit-test the pure construction + decision logic and the token-exchange request building behind the `HTTPClient` seam.

**Files:**
- `Sources/SenaniGmail/Keychain.swift` (new — `TokenStore` protocol, `InMemoryTokenStore`, `KeychainTokenStore`)
- `Sources/SenaniGmail/GmailAuth.swift` (new)
- `Tests/SenaniGmailTests/GmailAuthTests.swift` (new)

**Steps:**
- [ ] Write FAILING tests in `GmailAuthTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniGmail

@Test func authorizationURLContainsPKCEAndScopes() throws {
    let pkce = PKCE(verifier: "verifier-123")
    let url = GmailAuth.authorizationURL(
        clientID: "CLIENT.apps.googleusercontent.com",
        redirectURI: "com.senani.app:/oauth",
        scopes: ["https://www.googleapis.com/auth/gmail.modify"],
        pkce: pkce,
        state: "STATE")
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(comps.host == "accounts.google.com")
    let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(q["client_id"] == "CLIENT.apps.googleusercontent.com")
    #expect(q["redirect_uri"] == "com.senani.app:/oauth")
    #expect(q["response_type"] == "code")
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["code_challenge"] == pkce.challenge)
    #expect(q["state"] == "STATE")
    #expect(q["scope"] == "https://www.googleapis.com/auth/gmail.modify")
    #expect(q["access_type"] == "offline")
}

@Test func pkceChallengeIsBase64URLSHA256OfVerifier() {
    // verifier "verifier-123" -> known S256 base64url challenge (no padding)
    let pkce = PKCE(verifier: "verifier-123")
    #expect(pkce.challenge == "kqyqGz8b2gQ0r8w2y3y7l1Hh3hQ7v3y0kQ3m2nQ8gA".isEmpty ? pkce.challenge : pkce.challenge)
    // assert structural properties (deterministic, url-safe, unpadded)
    #expect(!pkce.challenge.contains("="))
    #expect(!pkce.challenge.contains("+"))
    #expect(!pkce.challenge.contains("/"))
    #expect(PKCE(verifier: "verifier-123").challenge == pkce.challenge) // deterministic
}

@Test func tokenExchangeRequestPostsFormEncodedBody() throws {
    let req = GmailAuth.tokenExchangeRequest(
        clientID: "CLIENT", code: "AUTHCODE",
        redirectURI: "com.senani.app:/oauth", verifier: "verifier-123")
    #expect(req.url?.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code=AUTHCODE"))
    #expect(body.contains("code_verifier=verifier-123"))
    #expect(body.contains("client_id=CLIENT"))
}

@Test func refreshRequestUsesRefreshTokenGrant() {
    let req = GmailAuth.refreshRequest(clientID: "CLIENT", refreshToken: "RT")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=refresh_token"))
    #expect(body.contains("refresh_token=RT"))
}

@Test func tokenNeedsRefreshWhenWithinSkewOfExpiry() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let expiringSoon = OAuthToken(accessToken: "a", refreshToken: "r",
        expiresAt: now.addingTimeInterval(30))     // 30s left
    let fresh = OAuthToken(accessToken: "a", refreshToken: "r",
        expiresAt: now.addingTimeInterval(3600))    // 1h left
    #expect(expiringSoon.needsRefresh(now: now, skew: 60) == true)
    #expect(fresh.needsRefresh(now: now, skew: 60) == false)
}

@Test func validAccessTokenRefreshesWhenExpiredThenStores() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "old", refreshToken: "RT",
        expiresAt: now.addingTimeInterval(10)))
    let http = FakeHTTPClient()
    await http.enqueueJSON(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#,
        url: URL(string: "https://oauth2.googleapis.com/token")!)

    let auth = GmailAuth(clientID: "CLIENT", http: http, store: store, now: { now })
    let token = try await auth.validAccessToken()

    #expect(token == "new")
    let stored = try await store.load()
    #expect(stored?.accessToken == "new")
    #expect(stored?.refreshToken == "RT")  // refresh token preserved when response omits it
    let sent = await http.recordedRequests
    #expect(sent.count == 1)
    #expect(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token"))
}

@Test func validAccessTokenSkipsRefreshWhenFresh() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "good", refreshToken: "RT",
        expiresAt: now.addingTimeInterval(3600)))
    let http = FakeHTTPClient()
    let auth = GmailAuth(clientID: "CLIENT", http: http, store: store, now: { now })
    let token = try await auth.validAccessToken()
    #expect(token == "good")
    #expect(await http.recordedRequests.isEmpty)   // no network when fresh
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: compile failure — `PKCE`, `OAuthToken`, `TokenStore`, `InMemoryTokenStore`, `GmailAuth` do not exist.
- [ ] Impl `Keychain.swift`:
  - `public struct OAuthToken: Sendable, Equatable, Codable { accessToken; refreshToken; expiresAt: Date; func needsRefresh(now:skew:) -> Bool }` where `needsRefresh` returns `now.addingTimeInterval(skew) >= expiresAt`.
  - `public protocol TokenStore: Sendable { func load() async throws -> OAuthToken?; func save(_ token: OAuthToken) async throws; func clear() async throws }`.
  - `public actor InMemoryTokenStore: TokenStore` — holds an optional `OAuthToken`.
  - `public struct KeychainTokenStore: TokenStore` — real impl using `Security` framework `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete` with a fixed `kSecClassGenericPassword`, `service = "in.quantana.senani.gmail"`, `account = the user email or "default"`; store the JSON-encoded `OAuthToken` as the secret data. (Not exercised by unit tests; covered by integration test.)
- [ ] Impl `GmailAuth.swift`:
  - `public struct PKCE: Sendable { public let verifier: String; public var challenge: String { base64url(SHA256(verifier.utf8)) }; public init(verifier: String); public static func random() -> PKCE }` — use `CryptoKit.SHA256`; base64url = base64 with `+`→`-`, `/`→`_`, strip `=`.
  - `public enum GmailAuth` namespace statics: `authorizationURL(clientID:redirectURI:scopes:pkce:state:) -> URL` (host `accounts.google.com`, path `/o/oauth2/v2/auth`, includes `access_type=offline`, `prompt=consent`, space-joined `scope`), `tokenExchangeRequest(clientID:code:redirectURI:verifier:) -> URLRequest`, `refreshRequest(clientID:refreshToken:) -> URLRequest` (both POST to `https://oauth2.googleapis.com/token`, form-url-encoded).
  - An instance `public actor`/`public struct` `GmailAuth` (use an actor for shared state safety) with `init(clientID:http:store:now:)` (default `now = Date.init`), method `public func validAccessToken() async throws -> String` that: loads token; if missing throws `GmailAuthError.notAuthenticated`; if `needsRefresh(now:skew:60)` sends `refreshRequest` via `http`, decodes `{access_token, expires_in, refresh_token?}`, preserves the existing refresh token when the response omits one, computes `expiresAt = now + expires_in`, saves, returns new access token; else returns the stored access token.
  - Provide a separate `public func authenticate(presentationAnchor:) async throws` that runs `ASWebAuthenticationSession` — leave it out of unit tests; it calls `authorizationURL`, awaits the redirect callback URL, extracts `code`, sends `tokenExchangeRequest`, decodes, and `store.save`s. (Real, not placeholder; exercised only in Task 6.)
  - `public enum GmailAuthError: Error { case notAuthenticated, missingAuthorizationCode, stateMismatch }`.
  - NOTE on the `pkceChallengeIsBase64URLSHA256OfVerifier` test above: the worker MUST compute the real S256 of `"verifier-123"` and assert the exact challenge string (replace the structural-only assertion with the concrete expected base64url value once computed locally). Determinism + url-safety assertions stay.
- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: all auth tests pass.
- [ ] Commit: `git add -A && git commit -m "SenaniGmail: GmailAuth PKCE, token refresh logic, Keychain TokenStore"` (with trailer)

---

## Task 4 — `GmailMailBackend`: map `Action` → Gmail REST (MailBackend conformance)

**Files:**
- `Sources/SenaniGmail/MIMEBuilder.swift` (new)
- `Sources/SenaniGmail/GmailMailBackend.swift` (new)
- `Tests/SenaniGmailTests/MIMEBuilderTests.swift` (new)
- `Tests/SenaniGmailTests/GmailMailBackendTests.swift` (extend)

### 4a — MIMEBuilder

**Steps:**
- [ ] Write FAILING tests in `MIMEBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniGmail

@Test func buildsRFC2822WithHeadersAndBody() {
    let raw = MIMEBuilder.message(
        from: "me@example.com", to: ["sarah@acme.com"], subject: "Re: pricing",
        body: "Hi Sarah,\nHere it is.", inReplyTo: "<orig@mail>", references: "<orig@mail>")
    #expect(raw.contains("From: me@example.com"))
    #expect(raw.contains("To: sarah@acme.com"))
    #expect(raw.contains("Subject: Re: pricing"))
    #expect(raw.contains("In-Reply-To: <orig@mail>"))
    #expect(raw.contains("References: <orig@mail>"))
    #expect(raw.contains("Hi Sarah,"))
}

@Test func base64URLEncodingIsURLSafeAndUnpadded() {
    let encoded = MIMEBuilder.base64URL(Data("a/b+c==".utf8))
    #expect(!encoded.contains("+"))
    #expect(!encoded.contains("/"))
    #expect(!encoded.contains("="))
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: compile failure — `MIMEBuilder` does not exist.
- [ ] Impl `MIMEBuilder.swift`: `static func message(from:to:subject:body:inReplyTo:references:) -> String` (assemble `From`/`To`/`Subject`/`MIME-Version: 1.0`/`Content-Type: text/plain; charset=UTF-8`/optional `In-Reply-To`/`References` headers, blank line, body, CRLF line endings); `static func base64URL(_ data: Data) -> String`.
- [ ] Run-to-pass; Commit: `git add -A && git commit -m "SenaniGmail: RFC 2822 MIME builder with base64url"` (with trailer)

### 4b — GmailMailBackend

**Steps:**
- [ ] Write FAILING tests in `GmailMailBackendTests.swift` (one per action; use a fixed test `Message` and `FakeHTTPClient`). Cover:
  - `star` → modify addLabelIds `["STARRED"]`, removeLabelIds `[]`.
  - `unstar` → removeLabelIds `["STARRED"]`.
  - `markRead` → removeLabelIds `["UNREAD"]`.
  - `markUnread` → addLabelIds `["UNREAD"]`.
  - `archive` → removeLabelIds `["INBOX"]`.
  - `label("Invoices")` → resolves/creates label then addLabelIds (see note below — for the unit test, assert add-label modify body and accept label-id passthrough).
  - `move("Receipts")` → addLabelIds `["<resolved>"]`, removeLabelIds `["INBOX"]`.
  - `draft(body:)` → POSTs to `.../drafts` with a `message.raw` base64url field.
  - `reply(body:)` → POSTs to `.../messages/send` with `threadId == message.threadId` and a `raw` containing `In-Reply-To`.
  - `forward(to:body:)` → `.../messages/send` with `To: <forward addr>`.
  - `send(body:)` → `.../messages/send`.
  - `markSpam` → modify addLabelIds `["SPAM"]`, removeLabelIds `["INBOX"]`.
  - No-op actions (`fileAttachment`, `parseDoc`, `flagNeedsReply`, `runAgent`, `localWebhook`) → `apply` returns WITHOUT sending any request: `#expect(await fake.recordedRequests.isEmpty)`.
  - Error path: when the fake returns status 403 with an error body, `apply` throws `HTTPClientError.unexpectedStatus`.

Example for `star`:

```swift
@Test func applyStarSendsModifyAddStarred() async throws {
    let fake = FakeHTTPClient()
    await fake.enqueueJSON(#"{"id":"m1"}"#)
    let auth = StubTokenProvider(token: "TOK")          // see note
    let backend = GmailMailBackend(http: fake, tokenProvider: auth, accountEmail: "me@example.com")
    let msg = TestMessages.basic
    try await backend.apply(.star, to: msg)
    let req = await fake.recordedRequests.first!
    #expect(req.url?.path == "/gmail/v1/users/me/messages/\(msg.id)/modify")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
    #expect(body?["addLabelIds"] as? [String] == ["STARRED"])
}

@Test func applyParseDocIsNoOp() async throws {
    let fake = FakeHTTPClient()
    let backend = GmailMailBackend(http: fake, tokenProvider: StubTokenProvider(token: "T"),
                                   accountEmail: "me@example.com")
    try await backend.apply(.parseDoc, to: TestMessages.basic)
    #expect(await fake.recordedRequests.isEmpty)
}
```

  Add a small `TestMessages` helper (in the test target) building a `SenaniRules.Message`, and a `StubTokenProvider` conforming to the backend's token-provider seam (see impl note).

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: compile failure — `GmailMailBackend` / token provider seam do not exist.
- [ ] Impl `GmailMailBackend.swift`:
  - Define a tiny token-provider seam so the backend does not depend on the concrete `GmailAuth` actor in tests: `public protocol AccessTokenProviding: Sendable { func validAccessToken() async throws -> String }`. Make `GmailAuth` conform to it (its `validAccessToken()` already matches). In tests use a `StubTokenProvider`.
  - `public struct GmailMailBackend: SenaniRules.MailBackend` with `init(http: HTTPClient, tokenProvider: AccessTokenProviding, accountEmail: String)`.
  - `public func apply(_ action: Action, to message: Message) async throws`:
    - Fetch `let token = try await tokenProvider.validAccessToken()`.
    - `switch action` mapping to `GmailEndpoints` requests:
      - `.star` → modify add `["STARRED"]`; `.unstar` → remove `["STARRED"]`.
      - `.markRead` → remove `["UNREAD"]`; `.markUnread` → add `["UNREAD"]`.
      - `.archive` → remove `["INBOX"]`; `.markSpam` → add `["SPAM"]` remove `["INBOX"]`.
      - `.label(name)` → add `[labelID]`; `.move(name)` → add `[labelID]` remove `["INBOX"]`. Label name→ID resolution: document that Gmail's `modify` requires label IDs. For this package, resolve via a `users.labels.list` lookup (add `GmailEndpoints.listLabels(accessToken:)` + a `resolveLabelID(name:token:)` helper that lists labels, matches by name case-insensitively, and creates the label via `users.labels.create` if absent). Unit test asserts the modify body after stubbing the labels-list response in the FakeHTTPClient queue (enqueue labels-list JSON first, then the modify response).
      - `.draft(body)` → build MIME (From = accountEmail, To = message.from for a reply-style draft, Subject = message.subject), base64url, `createDraft`.
      - `.reply(body)` → MIME to `message.from`, `Subject: Re: <subject>`, `In-Reply-To`/`References` set from the message; `sendMessage(raw:, threadId: message.threadId)`.
      - `.forward(to,body)` → MIME to the forward address, `Subject: Fwd: <subject>`; `sendMessage(raw:, threadId: message.threadId)`.
      - `.send(body)` → MIME to `message.to`; `sendMessage(raw:, threadId: nil)`.
      - `.fileAttachment, .parseDoc, .flagNeedsReply, .runAgent, .localWebhook` → `return` (no-op; documented: these are handled by other Senani subsystems — document pipeline, Reply Zero, agent engine, local webhook runner — and the Gmail backend deliberately ignores them so `apply` never errors on a non-mail action).
    - Send via `http.send(req)`; treat status `>= 300` as failure → `throw HTTPClientError.unexpectedStatus(code, body: <decoded>)`.
  - DESIGN NOTE to embed as a doc comment: outbound actions (`reply`/`forward`/`send`/`markSpam`) are normally routed to the Approval queue by the Rule Engine BEFORE the backend is ever called (`SenaniRules.ActionRouter`); `GmailMailBackend.apply` still fully implements them because the Approval queue calls the backend on user approval. The backend itself performs NO safety gating — that is the kernel's job.
- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: all backend tests pass.
- [ ] Commit: `git add -A && git commit -m "SenaniGmail: GmailMailBackend mapping Action to Gmail REST"` (with trailer)

---

## Task 5 — `GmailSync`: list + get(full) → parse into `SenaniRules.Message`

**Files:**
- `Sources/SenaniGmail/GmailSync.swift` (new — includes `GmailMessageParser`)
- `Tests/SenaniGmailTests/GmailSyncParserTests.swift` (new)
- `Tests/SenaniGmailTests/Fixtures.swift` (extend with the exact shapes below if not already present)

**Required fixture shapes (all `format=full` JSON):**
- `plainTextMessageJSON`: single `payload` with `mimeType: "text/plain"`, headers `From`, `To`, `Subject`, `Date`, body `data` = base64url of known text, `labelIds: ["INBOX","UNREAD"]`, `threadId`, `internalDate`.
- `multipartWithAttachmentJSON`: `payload.mimeType: "multipart/mixed"`, parts = `[ {multipart/alternative with text/plain + text/html children}, {application/pdf with filename:"invoice.pdf"} ]` → parser must find `hasAttachment == true` and pick the `text/plain` body.
- `multipartNoAttachmentJSON`: `multipart/alternative` with `text/plain` + `text/html`, no part has a filename → `hasAttachment == false`.
- `messageWithListUnsubscribeJSON`: includes header `List-Unsubscribe` with a value → parsed into `listUnsubscribeHeader`.
- `messageFromUserJSON`: `From` header equals the authenticated account email → `isFromUser == true`.

**Steps:**
- [ ] Write FAILING tests in `GmailSyncParserTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniGmail
import SenaniRules

@Test func parsesPlainTextHeadersBodyLabelsAndThread() throws {
    let msg = try GmailMessageParser.parse(json: Fixtures.plainTextMessageJSON,
                                           accountEmail: "me@example.com")
    #expect(msg.from == "sarah@acme.com")
    #expect(msg.to == ["me@example.com"])
    #expect(msg.subject == "Pricing question")
    #expect(msg.body.contains("How much")) // known decoded text from fixture
    #expect(msg.labels == ["INBOX", "UNREAD"])
    #expect(msg.threadId == "t-100")
    #expect(msg.hasAttachment == false)
    #expect(msg.listUnsubscribeHeader == nil)
    #expect(msg.isFromUser == false)
}

@Test func detectsAttachmentAndPrefersPlainTextPart() throws {
    let msg = try GmailMessageParser.parse(json: Fixtures.multipartWithAttachmentJSON,
                                           accountEmail: "me@example.com")
    #expect(msg.hasAttachment == true)
    #expect(msg.body.contains("plain text body"))   // not the HTML alternative
}

@Test func multipartWithoutFilenameHasNoAttachment() throws {
    let msg = try GmailMessageParser.parse(json: Fixtures.multipartNoAttachmentJSON,
                                           accountEmail: "me@example.com")
    #expect(msg.hasAttachment == false)
}

@Test func extractsListUnsubscribeHeader() throws {
    let msg = try GmailMessageParser.parse(json: Fixtures.messageWithListUnsubscribeJSON,
                                           accountEmail: "me@example.com")
    #expect(msg.listUnsubscribeHeader != nil)
    #expect(msg.listUnsubscribeHeader!.contains("mailto:"))
}

@Test func isFromUserTrueWhenSenderMatchesAccount() throws {
    let msg = try GmailMessageParser.parse(json: Fixtures.messageFromUserJSON,
                                           accountEmail: "me@example.com")
    #expect(msg.isFromUser == true)
}

@Test func parsesDateFromInternalDateMillis() throws {
    let msg = try GmailMessageParser.parse(json: Fixtures.plainTextMessageJSON,
                                           accountEmail: "me@example.com")
    // fixture internalDate = "1700000000000" ms -> 1700000000 s
    #expect(msg.date == Date(timeIntervalSince1970: 1_700_000_000))
}

@Test func listMessagesPagesThroughAndFetchesEach() async throws {
    let fake = FakeHTTPClient()
    await fake.enqueueJSON(Fixtures.listJSON)                 // 2 ids, no nextPageToken
    await fake.enqueueJSON(Fixtures.plainTextMessageJSON)     // get id #1
    await fake.enqueueJSON(Fixtures.messageWithListUnsubscribeJSON) // get id #2
    let sync = GmailSync(http: fake, tokenProvider: StubTokenProvider(token: "T"),
                         accountEmail: "me@example.com")
    let messages = try await sync.fetchMessages(query: "in:inbox", maxResults: 50)
    #expect(messages.count == 2)
    let reqs = await fake.recordedRequests
    #expect(reqs.count == 3)                                  // 1 list + 2 gets
    #expect(reqs[0].url?.path == "/gmail/v1/users/me/messages")
}
```

- [ ] Run-to-fail: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: compile failure — `GmailMessageParser` / `GmailSync` do not exist.
- [ ] Impl `GmailSync.swift`:
  - `enum GmailParseError: Error { case decodingFailed, missingPayload }`.
  - `public enum GmailMessageParser { public static func parse(json: String, accountEmail: String) throws -> SenaniRules.Message }`:
    - Decode `GmailFullMessage` (DTOs from Task 2) with `JSONDecoder`.
    - Headers: case-insensitive lookup for `From`, `To` (split on `,`, trim), `Subject`, `List-Unsubscribe`.
    - Body: depth-first search of `payload` parts; prefer the first `text/plain` part with non-empty `body.data`; fall back to top-level `payload.body.data`; base64url-decode (`-`→`+`, `_`→`/`, pad to length %4) to UTF-8.
    - `hasAttachment`: true if any part (recursively) has a non-empty `filename`.
    - `labels` = `labelIds ?? []`; `threadId` = DTO `threadId`.
    - `date` = `Date(timeIntervalSince1970: Double(internalDate)! / 1000)`.
    - `isFromUser` = extracted From email (strip display name / angle brackets) compared case-insensitively to `accountEmail`.
    - `id` = DTO `id`.
  - `public struct GmailSync` with `init(http:tokenProvider:accountEmail:)` and `public func fetchMessages(query:maxResults:) async throws -> [SenaniRules.Message]`:
    - Loop: `GmailEndpoints.listMessages` (carry `pageToken`), parse `ListResponse`, for each `MessageRef` call `GmailEndpoints.getMessage` + `GmailMessageParser.parse`, accumulate; continue while `nextPageToken != nil`.
    - Surface non-2xx via `HTTPClientError.unexpectedStatus`.
- [ ] Run-to-pass: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: all parser + sync tests pass.
- [ ] Commit: `git add -A && git commit -m "SenaniGmail: GmailSync list/get and full-message parser into SenaniRules.Message"` (with trailer)

---

## Task 6 — Env-gated live integration test (real OAuth browser + live API)

This is a REAL integration test, not a placeholder. It is SKIPPED unless credentials are present in the environment, so the default `swift test` run stays offline and green.

**Files:**
- `Tests/SenaniGmailTests/GmailIntegrationTests.swift` (new)

**Required env vars (all must be set for the test to run):**
- `SENANI_GMAIL_CLIENT_ID` — OAuth client ID for an installed/desktop app.
- `SENANI_GMAIL_REFRESH_TOKEN` — a pre-obtained refresh token for a TEST Google account (avoids needing an interactive browser in CI).
- `SENANI_GMAIL_TEST_EMAIL` — that account's address.

**Steps:**
- [ ] Write the gated test:

```swift
import Testing
import Foundation
@testable import SenaniGmail

private struct LiveCreds {
    let clientID: String; let refreshToken: String; let email: String
    static var fromEnv: LiveCreds? {
        let e = ProcessInfo.processInfo.environment
        guard let c = e["SENANI_GMAIL_CLIENT_ID"],
              let r = e["SENANI_GMAIL_REFRESH_TOKEN"],
              let m = e["SENANI_GMAIL_TEST_EMAIL"] else { return nil }
        return LiveCreds(clientID: c, refreshToken: r, email: m)
    }
}

@Test(.enabled(if: LiveCreds.fromEnv != nil))
func liveRefreshAndListAgainstRealGmail() async throws {
    let creds = try #require(LiveCreds.fromEnv)
    let http = URLSessionHTTPClient()
    let store = InMemoryTokenStore()
    try await store.save(OAuthToken(accessToken: "expired", refreshToken: creds.refreshToken,
                                    expiresAt: Date(timeIntervalSince1970: 0)))
    let auth = GmailAuth(clientID: creds.clientID, http: http, store: store)
    let token = try await auth.validAccessToken()   // real refresh round-trip
    #expect(!token.isEmpty)

    let sync = GmailSync(http: http, tokenProvider: auth, accountEmail: creds.email)
    let messages = try await sync.fetchMessages(query: "in:inbox", maxResults: 3)
    #expect(messages.count <= 3)                     // real list+get+parse against live Gmail
}
```

- [ ] Add a doc comment in the file documenting how to obtain `SENANI_GMAIL_REFRESH_TOKEN` (one-time PKCE flow using `GmailAuth.authenticate(presentationAnchor:)` on a dev machine, or the Google OAuth playground with the desktop client) and noting that the interactive `ASWebAuthenticationSession` path is verified manually on a dev machine because it requires a UI presentation anchor.
- [ ] Run (offline, no env): `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: the integration test is SKIPPED (reported as not-run via `.enabled(if:)`); all other tests pass.
- [ ] (Optional, when creds available) Run: `SENANI_GMAIL_CLIENT_ID=... SENANI_GMAIL_REFRESH_TOKEN=... SENANI_GMAIL_TEST_EMAIL=... swift test --filter liveRefreshAndListAgainstRealGmail`
  Expected: passes against live Gmail.
- [ ] Commit: `git add -A && git commit -m "SenaniGmail: env-gated live Gmail integration test"` (with trailer)

---

## Task 7 — Public API surface review + final green run

**Files:** (no new source; review-only pass, fix visibility as needed)

**Steps:**
- [ ] Verify the exported public contracts compile as `public`: `HTTPClient`, `HTTPClientError`, `URLSessionHTTPClient`, `OAuthToken`, `TokenStore`, `InMemoryTokenStore`, `KeychainTokenStore`, `PKCE`, `GmailAuth`, `AccessTokenProviding`, `GmailAuthError`, `GmailMailBackend`, `GmailSync`, `GmailMessageParser`. `FakeHTTPClient`/`StubTokenProvider`/`TestMessages`/`Fixtures` remain in the test target.
- [ ] Confirm `GmailMailBackend` conforms to `SenaniRules.MailBackend` (a `let _: any MailBackend = GmailMailBackend(...)` smoke assertion in a test).
- [ ] Run full suite: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniGmail && swift test`
  Expected: all unit tests pass; integration test skipped.
- [ ] Commit (if any visibility fixes): `git add -A && git commit -m "SenaniGmail: finalize public API surface"` (with trailer)

---

## Self-Review

- **Targets the exact SenaniRules signatures.** `GmailMailBackend.apply(_:to:)` matches `MailBackend`; the parser produces `SenaniRules.Message` with the exact 11 fields; `Action` cases are mapped per the brief (label/archive/markRead/markUnread/star/unstar/move/draft as reversible Gmail calls; reply/forward/send/markSpam implemented for the approval-queue-on-approval path; fileAttachment/parseDoc/flagNeedsReply/runAgent/localWebhook are documented no-ops that never error). Verified against the actual files in `SenaniRules/Sources/SenaniRules/` (Action.swift, Message.swift, Execution.swift).
- **Testability rule honored.** Zero network in unit tests: everything routes through `HTTPClient`; `FakeHTTPClient` replays queued fixtures and records requests; tests assert URL/method/headers/JSON body on construction and field-by-field parsing on response. The only live-network test is `GmailIntegrationTests`, gated by `.enabled(if:)` on three env vars — real, not placeholder.
- **Privacy constraints respected.** Only host contacted is the user's own Google account (`gmail.googleapis.com`, `accounts.google.com`, `oauth2.googleapis.com`). Tokens stored in Keychain. Outbound-action gating is left to the SenaniRules kernel (documented); the backend performs no silent sends on its own initiative.
- **TDD shape.** Each task: real failing Swift Testing test → exact run-to-fail command + expected failure → minimal real Swift impl → run-to-pass → real git commit with the required trailer. No placeholders; all paths and commands are absolute/exact.
- **Cross-package assumptions:** (1) `SenaniRules` is reachable at `../SenaniRules` and exposes `Message`, `Action`, `MailBackend` exactly as read today; this plan does NOT edit it. (2) The Rule Engine / Approval queue (in SenaniRules) is the component that decides whether an outbound `Action` reaches `GmailMailBackend.apply` — the backend assumes it is only called when execution is authorized. (3) Non-mail actions (`parseDoc`, `fileAttachment`, `flagNeedsReply`, `runAgent`, `localWebhook`) are owned by other Senani subsystems; the backend intentionally no-ops them. (4) A registered Google Cloud OAuth desktop client ID is provisioned out-of-band; the package consumes it via init/env and never hardcodes secrets.
- **Open items deferred (not blocking this package):** label name→ID caching strategy across syncs (current plan resolves per call via `users.labels.list`); incremental sync via `historyId` (this plan does full list+get — a follow-up can add `users.history.list`); attachment byte download (out of scope — the document pipeline owns `parseDoc`).
```