# App Shell & Composition Root Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Phase-0 SwiftUI **App Shell & Composition Root** — the unblocker every UI/agent plan depends on. Build a CLI-reproducible macOS app target that depends on all nine frozen engine packages plus the new `SenaniEngine`, and ship the `@MainActor final class AppEnvironment: ObservableObject` composition root EXACTLY as pinned in the reconciliation doc §3 (`database, messages, rules, approvals, audit, index, generator, embedder, gmail, orchestrator, scheduler`, plus `live() throws` and `preview()`). Wire a sidebar navigation skeleton (Inbox / Approvals / Activity / Settings) with placeholder destinations, inject `AppEnvironment` through `@EnvironmentObject`, and prove with tests that `preview()` builds a complete graph and the root scene instantiates against it.

**Architecture:** A **SwiftPM executable package** (`SenaniApp`, already scaffolded at repo-root `SenaniApp/`) that path-depends on `Packages/Senani*` and the new `Packages/SenaniEngine`. The composition root is the ONLY place stores/backends are constructed (reconciliation §4.1); every screen receives them via `@EnvironmentObject AppEnvironment`. `live()` builds a file-backed graph in Application Support (`SenaniDatabase.file(at:)`, `SqliteVecIndex`, `KeychainTokenStore`, a `NotReadyTextGenerator` stub until the MLX picker selects a model, and the real `GmailAuth`). `preview()` builds an in-memory graph (`SenaniDatabase.inMemory()`, `InMemoryVectorIndex`, an app-local `FakeTextGenerator`/`FakeEmbedder`, `InMemoryTokenStore`) so previews and UI tests need no Keychain/MLX/network. `Orchestrator`/`Scheduler` are constructed to the §3 `SenaniEngine` contract — `SenaniEngine` is built by a separate plan; this plan codes to its pinned signatures and records the build-order dependency.

**Tech Stack:** Swift 6.2 (strict concurrency, `swift-tools-version: 6.0`), Swift Package Manager (executable product), SwiftUI, Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14, Apple Silicon. No Xcode project file required — the executable target builds, runs, and tests from the CLI (`swift build` / `swift run` / `swift test`), so subagents can verify it headlessly.

**Working directory:** All `swift` commands run from the repo-root `SenaniApp/` directory (the executable package), unless stated otherwise. Engine packages live at `../Packages/Senani*` relative to it.

**Design spec / source of truth:** `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` — this plan implements **§3 "Composition root"** and the §4 conventions. The DesignSystem (`Gold`, `GlassPanel`, `AutonomyDial`) is a SEPARATE plan; this plan uses only minimal inline styling for placeholders and does not pin design tokens. The MLX model picker/downloader that swaps the `generator` from the `NotReady` stub to a live `MLXTextGenerator` is a SEPARATE plan; this plan only defines the stub. Gmail OAuth onboarding UI is a SEPARATE plan; this plan only constructs the `GmailAuth` actor.

**Out of scope (separate plans):** `SenaniEngine` package itself (Orchestrator/Scheduler/Agent implementations); the gold-glass DesignSystem package; MLX model picker + Hugging Face downloader; Gmail OAuth consent UI; the actual Inbox cockpit / Approval queue / Activity log / Settings screens (this plan ships placeholder destinations only); Triage / Reply Drafter agents.

---

## Why SwiftPM executable (not xcodegen / a checked-in .xcodeproj)

The decision and its justification, recorded so dependents do not relitigate it:

- **Reproducible from the CLI.** A SwiftPM `.executableTarget` builds, runs, and tests headlessly with `swift build` / `swift run SenaniApp` / `swift test`. Subagents and CI can verify the app compiles and the root scene instantiates without opening Xcode, without a GUI, and without a code-signing identity. An `.xcodeproj` (hand-maintained or xcodegen-generated) requires `xcodebuild` + a scheme + (for a real `.app`) signing — heavier and flakier in an automated worktree.
- **Local package graph is native to SwiftPM.** The shell must depend on nine local `Packages/Senani*` packages plus the new `Packages/SenaniEngine`. SwiftPM `.package(path:)` resolves these directly; the engine packages are already SwiftPM packages, so no bridging layer is needed.
- **Already scaffolded.** A `SenaniApp/` executable package already exists at repo root, wired to all nine packages. This plan upgrades its tools version, adds the `SenaniEngine` dependency + a test target, and replaces the ad-hoc `AppState` with the pinned `AppEnvironment`.
- **The cost we accept:** a `swift run` executable does not produce a signed, sandboxed `.app` bundle with an `Info.plist`/entitlements. That is fine for Phase 0 (the Roadmap's "app skeleton with a model running"). **Packaging into a notarized `.app` is explicitly a Deferred-phase concern** (reconciliation §5: code signing / notarization). When that lands, a thin generated `xcodeproj` (or `swift build` + a packaging script) wraps this same `SenaniApp` target — the composition root and views are unchanged. Recorded so the deferred packaging plan knows the target name and entry point.

> **SwiftUI `@main` in a SwiftPM executable target:** an `@main struct App: SwiftUI.App` is a valid entry point for an executable target on macOS 14. Do NOT also add a `main.swift` file — two entry points conflict. The single `SenaniApp.swift` carrying `@main` is the entry point.

---

## Cross-package assumptions (state these to the human before coding)

These are the **real, source-verified** upstream signatures this plan wires (read from `Packages/Senani*/Sources`, not just the reconciliation doc). Where the live source DEVIATES from reconciliation §2/§3, the deviation is flagged — code to the real source.

### `SenaniStore` (frozen — verified)
```swift
public final class SenaniDatabase: @unchecked Sendable {   // NOTE: @unchecked Sendable, not Sendable
    public let queue: DatabaseQueue
    public static func inMemory() throws -> SenaniDatabase
    public static func file(at path: String) throws -> SenaniDatabase
}
public struct MessageStore: Sendable { public init(database: SenaniDatabase) }
public struct RuleStore: Sendable    { public init(database: SenaniDatabase) }
public struct ApprovalStore: Sendable {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)   // DEVIATION: reconciliation §2 listed init(database:) only — real init REQUIRES now:
}
public actor PersistentAuditLog: SenaniRules.AuditLog {
    public init(database: SenaniDatabase, now: @escaping @Sendable () -> Double)
}
public protocol VectorIndex: Sendable {
    func insert(id: String, vector: [Float], metadata: [String: String]) throws
    func search(vector: [Float], k: Int) throws -> [VectorHit]
}
public final class InMemoryVectorIndex: VectorIndex { public init() }
public final class SqliteVecIndex: VectorIndex {
    public init(database: SenaniDatabase, namespace: String = "default")            // DEVIATION: takes database + namespace, not a parameterless init
    public static func inMemory(namespace: String = "default") throws -> SqliteVecIndex
}
```

### `SenaniInference` (frozen — verified)
```swift
public protocol TextGenerator: Sendable {
    func generate(prompt: String, maxTokens: Int) async throws -> String
    func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
}
public protocol Embedder: Sendable { func embed(_ text: String) async throws -> [Float] }
public enum InferenceError: Error, Sendable, Equatable { case modelNotLoaded; case generationFailed(String); case decodingFailed(String) }
public final class MLXTextGenerator: TextGenerator, @unchecked Sendable { public init(modelPath: String) }   // live path; assumes weights on disk
public struct JSONSchema { public init(json: String) }
```
> **IMPORTANT DEVIATION:** `SenaniInference` ships **no `FakeTextGenerator` and no in-memory `Embedder`** (verified: only `MLXTextGenerator`, `MLXEmbedder`, `EmbeddingGemmaEmbedder` exist, all MLX-backed). Reconciliation §3 says `preview()` uses "a local `FakeTextGenerator`". Therefore this plan DEFINES `FakeTextGenerator` and `FakeEmbedder` **inside the `SenaniApp` target** (Task 3). The live `generator` is a `NotReadyTextGenerator` stub (also defined here, Task 3) that throws `InferenceError.modelNotLoaded` until the MLX picker plan injects a real `MLXTextGenerator`.

### `SenaniGmail` (frozen — verified)
```swift
public actor GmailAuth: AccessTokenProviding {
    public init(clientID: String, http: any HTTPClient, store: any TokenStore, now: @escaping @Sendable () -> Date = Date.init)
    public func validAccessToken() async throws -> String
}
public protocol TokenStore: Sendable { func save(_:) async throws; func load() async throws -> OAuthToken?; func clear() async throws }
public struct KeychainTokenStore: TokenStore { public init(service: String = "in.quantana.senani.gmail", account: String = "default") }
public actor InMemoryTokenStore: TokenStore { public init() }
public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
public struct URLSessionHTTPClient: HTTPClient { public init(session: URLSession = .shared) }
public struct GmailSync: Sendable {
    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding, accountEmail: String)
    public func fetchMessages(query: String, maxResults: Int) async throws -> [Message]
}
public struct GmailMailBackend: SenaniRules.MailBackend {
    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding, accountEmail: String)
}
```
> **OAuth client ID is a human-supplied open item** (reconciliation §5). `live()` reads it from an environment/Info value with a clearly-fake placeholder default; the onboarding plan wires the real consent flow. Constructing `GmailAuth` does NOT trigger any network call, so a placeholder client ID is safe at composition time.

### `SenaniRules` (frozen — verified)
```swift
public struct Message: Sendable, Codable, Identifiable {
    public init(id: String, from: String, to: [String], subject: String, body: String,
                hasAttachment: Bool, listUnsubscribeHeader: String?, labels: [String],
                threadId: String, date: Date, isFromUser: Bool)
}
public protocol MailBackend: Sendable { func apply(_ action: Action, to message: Message) async throws }
public protocol AuditLog: Sendable { func record(_ record: ActionRecord) async }
public actor InMemoryAuditLog: AuditLog { public init() }                 // tests; PersistentAuditLog is the live one
public enum Autonomy: String, Sendable, Equatable { case suggest, draft, auto }   // (rawValue-backed)
```

### `SenaniEngine` (NEW — DOES NOT EXIST YET; pinned by reconciliation §3)
`Packages/SenaniEngine` is built by the orchestrator plan. **This plan has a build-order dependency on it** (reconciliation §1: `SenaniEngine` → app shell). This plan codes the composition root to these EXACT pinned signatures; if `SenaniEngine`'s built API differs, the worker adapts `AppEnvironment.live()`/`preview()` and records the deviation in the reconciliation doc — never edits `SenaniEngine` to fit.
```swift
public actor Orchestrator {
    public init(registry: AgentRegistry, triage: any Agent, mailBackend: any MailBackend,
                approvals: ApprovalStore, audit: any AuditLog, messages: MessageStore,
                index: any VectorIndex, embedder: any Embedder, rules: RuleStore,
                now: @escaping @Sendable () -> Date)
    public func process(_ message: Message) async throws -> [ProcessedOutcome]
    public func processInbox() async throws -> [ProcessedOutcome]
}
public actor Scheduler {
    public init(sync: GmailSyncing, store: MessageStore, orchestrator: Orchestrator,
                interval: TimeInterval, now: @escaping @Sendable () -> Date)
    public func tick() async throws
    public func start() async
    public func stop() async
}
public struct AgentRegistry: Sendable { public init(agents: [any Agent]) }
public protocol Agent: Sendable { var id: String { get }; var autonomy: Autonomy { get } /* … */ }
public protocol GmailSyncing: Sendable { func fetchMessages(query: String, maxResults: Int) async throws -> [Message] }
```
> **Bootstrap-with-no-agents:** until the Triage/Reply-Drafter plans land, `live()`/`preview()` construct the `Orchestrator` with an EMPTY `AgentRegistry(agents: [])` and a no-op `triage` agent (an app-local `NoopAgent` that wakes for nothing). This keeps the graph complete and the app launchable in Phase 0 with no agents (Roadmap Phase-0 outcome: "no agents yet"). `GmailSync` conforms to `GmailSyncing` via a one-line app-tier extension (Task 4) — do not edit `SenaniGmail`.

---

## File Structure

```
SenaniApp/
  Package.swift                                  # MODIFY: tools 6.0, add SenaniEngine dep + test target + strict concurrency
  Sources/SenaniApp/
    SenaniApp.swift                              # MODIFY: @main App; build env (live, fallback preview); inject AppEnvironment
    AppEnvironment.swift                         # CREATE: the pinned composition root (live() / preview())
    Stubs/NotReadyTextGenerator.swift            # CREATE: TextGenerator stub — throws .modelNotLoaded until MLX picker swaps it
    Stubs/FakeTextGenerator.swift                # CREATE: app-local fake generator + FakeEmbedder for preview()/tests
    Stubs/NoopAgent.swift                        # CREATE: empty Agent for the no-agents Phase-0 orchestrator bootstrap
    Stubs/EngineAdapters.swift                   # CREATE: GmailSync: GmailSyncing conformance (one-line app-tier extension)
    AppSupport.swift                             # CREATE: Application Support directory resolution for the live DB file
    UI/RootScene.swift                           # CREATE: NavigationSplitView sidebar (Inbox/Approvals/Activity/Settings) + routing
    UI/NavigationItem.swift                      # CREATE: sidebar item enum (title + SF Symbol)
    UI/Placeholders.swift                        # CREATE: InboxPlaceholder / ApprovalsPlaceholder / ActivityPlaceholder / SettingsPlaceholder
  Tests/SenaniAppTests/
    AppEnvironmentTests.swift                    # CREATE: preview() builds a complete graph; live() into a temp dir builds
    RootSceneSmokeTests.swift                    # CREATE: root scene instantiates with preview() env (compile + construct smoke)
    StubsTests.swift                             # CREATE: NotReadyTextGenerator throws; FakeTextGenerator returns canned JSON
```

> The existing `Sources/SenaniApp/UI/{MainNavigationView,DetailView,Theme}.swift` and the ad-hoc `AppState` in `SenaniApp.swift` are REPLACED. `AppState` violates §3/§4 (it is `@Observable`, not the pinned `ObservableObject AppEnvironment`, and constructs only two stores). Task 8 deletes the obsolete files after the new `RootScene` is green.

---

### Task 1: Package manifest — tools 6.0, SenaniEngine dep, test target, strict concurrency

**Files:**
- Modify: `SenaniApp/Package.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/StubsTests.swift` (placeholder import-only test so the test target links)

- [ ] **Step 1: Write a failing import test**

Create `SenaniApp/Tests/SenaniAppTests/StubsTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniInference

@Test func testTargetLinksAppAndInference() {
    // Proves the SenaniAppTests target builds and links the SenaniApp module + SenaniInference.
    let err: InferenceError = .modelNotLoaded
    #expect(err == .modelNotLoaded)
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test
```

Expected: failure — no `SenaniAppTests` test target exists yet (`error: no test target` / `no such module SenaniApp` from the test target).

- [ ] **Step 3: Update the manifest**

Replace `SenaniApp/Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SenaniApp", targets: ["SenaniApp"])
    ],
    dependencies: [
        .package(path: "../Packages/SenaniRules"),
        .package(path: "../Packages/SenaniStore"),
        .package(path: "../Packages/SenaniInference"),
        .package(path: "../Packages/SenaniGmail"),
        .package(path: "../Packages/SenaniVoice"),
        .package(path: "../Packages/SenaniDocs"),
        .package(path: "../Packages/SenaniReplyZero"),
        .package(path: "../Packages/SenaniAnalytics"),
        .package(path: "../Packages/SenaniAssistant"),
        .package(path: "../Packages/SenaniEngine"),
    ],
    targets: [
        .executableTarget(
            name: "SenaniApp",
            dependencies: [
                "SenaniRules", "SenaniStore", "SenaniInference", "SenaniGmail",
                "SenaniVoice", "SenaniDocs", "SenaniReplyZero", "SenaniAnalytics",
                "SenaniAssistant", "SenaniEngine",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniAppTests",
            dependencies: ["SenaniApp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

> **BLOCKING PREREQUISITE:** `../Packages/SenaniEngine` must exist and resolve. If `swift test` fails to *resolve* the path dependency (not a code error), `SenaniEngine` has not been built yet — this is the build-order dependency from reconciliation §1. STOP and coordinate: the `SenaniEngine` orchestrator plan must complete first. Do NOT stub `SenaniEngine` inside `SenaniApp`. (If coordination requires unblocking the rest of this plan early, temporarily comment out the `SenaniEngine` dep + `Orchestrator`/`Scheduler` lines, complete Tasks 1–4 and 6–8, then re-enable for Task 5 — but the plan's definition of done REQUIRES `SenaniEngine` wired.)

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter testTargetLinksAppAndInference
```

Expected: 1 test passes (after the existing `SenaniApp.swift`/UI files still compile — they will until Task 8 replaces them; if the old `AppState` references break under language mode v6, proceed to Task 2 which rewrites the entry point).

> If the existing `MainNavigationView.swift`/`DetailView.swift`/`Theme.swift`/`AppState` fail to compile under strict concurrency in mode v6, that is expected — they are removed in Task 8. To get Task 1 green in isolation, you may temporarily empty `SenaniApp.swift`'s body to a minimal `@main` placeholder; the real entry point lands in Task 6. Prefer ordering: do Tasks 2–6 before re-running the full suite.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: manifest to tools 6.0, add SenaniEngine dep + test target + strict concurrency"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: Application Support directory resolution

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/AppSupport.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/AppEnvironmentTests.swift` (start the file with this test)

`live()` must place the SQLite file in `~/Library/Application Support/Senani/senani.sqlite`, creating the directory if needed. Isolate that logic so it is testable without touching the real home directory.

- [ ] **Step 1: Write a failing test**

Create `SenaniApp/Tests/SenaniAppTests/AppEnvironmentTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniApp

@Test func appSupportResolvesUnderBaseDirectoryAndCreatesIt() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("senani-test-\(UUID().uuidString)", isDirectory: true)
    let dbURL = try AppSupport.databaseURL(base: tmp, fileManager: .default)
    #expect(dbURL.lastPathComponent == "senani.sqlite")
    #expect(dbURL.deletingLastPathComponent().lastPathComponent == "Senani")
    // The Senani directory must have been created.
    var isDir: ObjCBool = false
    let dir = dbURL.deletingLastPathComponent().path
    #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
    #expect(isDir.boolValue == true)
    try? FileManager.default.removeItem(at: tmp)
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter appSupportResolvesUnderBaseDirectoryAndCreatesIt
```

Expected: failure — `AppSupport` undefined.

- [ ] **Step 3: Implement `AppSupport`**

Create `SenaniApp/Sources/SenaniApp/AppSupport.swift`:

```swift
import Foundation

/// Resolves on-disk locations for the live app graph. Kept tiny and injectable
/// so AppEnvironment.live() can place the database under the user's Application
/// Support directory while tests redirect to a temp directory.
public enum AppSupport {
    public static let folderName = "Senani"
    public static let databaseFileName = "senani.sqlite"

    /// Returns `<base>/Senani/senani.sqlite`, creating `<base>/Senani` if needed.
    /// In production `base` is the user's Application Support directory.
    public static func databaseURL(base: URL, fileManager: FileManager) throws -> URL {
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// The user's Application Support directory (the default `base` for live()).
    public static func applicationSupportBase(fileManager: FileManager) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter appSupportResolvesUnderBaseDirectoryAndCreatesIt
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: AppSupport resolves Application Support DB path"
```

(Append the standard trailer.)

---

### Task 3: Stubs — NotReadyTextGenerator, FakeTextGenerator + FakeEmbedder

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/Stubs/NotReadyTextGenerator.swift`
- Create: `SenaniApp/Sources/SenaniApp/Stubs/FakeTextGenerator.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/StubsTests.swift`

`SenaniInference` ships no fakes (verified). The live `generator` is `NotReadyTextGenerator` until the MLX picker injects a real one; `preview()`/tests use `FakeTextGenerator` + `FakeEmbedder`. All three live in the app target.

- [ ] **Step 1: Replace the placeholder test with real stub tests**

Replace `SenaniApp/Tests/SenaniAppTests/StubsTests.swift`:

```swift
import Testing
@testable import SenaniApp
import SenaniInference

@Test func notReadyGeneratorThrowsModelNotLoaded() async {
    let gen = NotReadyTextGenerator()
    await #expect(throws: InferenceError.modelNotLoaded) {
        _ = try await gen.generate(prompt: "hi", maxTokens: 8)
    }
    await #expect(throws: InferenceError.modelNotLoaded) {
        _ = try await gen.generateJSON(prompt: "hi", schema: JSONSchema(json: "{}"))
    }
}

@Test func fakeGeneratorReturnsCannedResponses() async throws {
    let gen = FakeTextGenerator(response: #"{ "ok": true }"#)
    let json = try await gen.generateJSON(prompt: "p", schema: JSONSchema(json: "{}"))
    #expect(json == #"{ "ok": true }"#)
    let text = try await gen.generate(prompt: "p", maxTokens: 4)
    #expect(text == #"{ "ok": true }"#)
}

@Test func fakeEmbedderReturnsFixedWidthVector() async throws {
    let emb = FakeEmbedder(dimension: 8)
    let v = try await emb.embed("anything")
    #expect(v.count == 8)
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter StubsTests
```

Expected: failure — `NotReadyTextGenerator` / `FakeTextGenerator` / `FakeEmbedder` undefined.

- [ ] **Step 3: Implement the stubs**

Create `SenaniApp/Sources/SenaniApp/Stubs/NotReadyTextGenerator.swift`:

```swift
import SenaniInference

/// The live `generator` before a model is chosen. Every call throws
/// `InferenceError.modelNotLoaded`. The MLX model-picker plan replaces this
/// with a real `MLXTextGenerator` once weights are on disk; UI that reaches a
/// generate call before then surfaces "no model selected".
public struct NotReadyTextGenerator: TextGenerator {
    public init() {}
    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw InferenceError.modelNotLoaded
    }
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        throw InferenceError.modelNotLoaded
    }
}
```

Create `SenaniApp/Sources/SenaniApp/Stubs/FakeTextGenerator.swift`:

```swift
import SenaniInference

/// App-local fake generator for previews and UI tests (SenaniInference ships no
/// fake). Returns a fixed canned response for every call.
public struct FakeTextGenerator: TextGenerator {
    private let response: String
    public init(response: String = #"{ "tool_calls": [], "reply": "" }"#) {
        self.response = response
    }
    public func generate(prompt: String, maxTokens: Int) async throws -> String { response }
    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String { response }
}

/// App-local fake embedder for previews and UI tests. Returns a deterministic
/// fixed-width zero vector so the in-memory vector index can accept inserts.
public struct FakeEmbedder: Embedder {
    private let dimension: Int
    public init(dimension: Int = 768) { self.dimension = dimension }
    public func embed(_ text: String) async throws -> [Float] {
        Array(repeating: 0, count: dimension)
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter StubsTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: NotReadyTextGenerator stub + app-local FakeTextGenerator/FakeEmbedder"
```

(Append the standard trailer.)

---

### Task 4: Engine bootstrap stubs — NoopAgent + GmailSyncing conformance

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/Stubs/NoopAgent.swift`
- Create: `SenaniApp/Sources/SenaniApp/Stubs/EngineAdapters.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/StubsTests.swift` (append)

The Phase-0 orchestrator runs with no agents: an empty `AgentRegistry` and a `NoopAgent` as the required `triage` argument. `Scheduler` needs a `GmailSyncing`; `GmailSync` conforms via a one-line app-tier extension.

> **DEPENDS ON `SenaniEngine`.** `NoopAgent` conforms to `SenaniEngine.Agent` whose full member set is pinned by reconciliation §3 (`id`, `autonomy`, `wakesFor(_:context:)`, `proposals(for:context:tools:)`). Code `NoopAgent` to the EXACT built `Agent` protocol; if a member name/signature differs from §3, match the built source and record the deviation. The skeleton below uses the §3 signatures.

- [ ] **Step 1: Append failing tests to `StubsTests.swift`**

Append to `SenaniApp/Tests/SenaniAppTests/StubsTests.swift`:

```swift
import SenaniEngine
import SenaniRules
import Foundation

@Test func noopAgentWakesForNothing() {
    let agent = NoopAgent()
    #expect(agent.id == "noop")
    let m = Message(id: "m1", from: "a@b.com", to: ["me@x.com"], subject: "S", body: "B",
                    hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                    threadId: "t1", date: Date(), isFromUser: false)
    let ctx = AgentContext(account: "me@x.com", thread: [m], rules: [],
                           retrieve: { _, _ in [] }, now: Date())
    #expect(agent.wakesFor(m, context: ctx) == false)
}
```

> If the built `AgentContext.init` differs from §3, adjust this test's `AgentContext(...)` to the real initializer and record the deviation — the assertion (`wakesFor == false`) is the load-bearing part.

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter noopAgentWakesForNothing
```

Expected: failure — `NoopAgent` undefined (or `SenaniEngine` unresolved → blocking prerequisite per Task 1).

- [ ] **Step 3: Implement the stubs**

Create `SenaniApp/Sources/SenaniApp/Stubs/NoopAgent.swift`:

```swift
import SenaniEngine
import SenaniRules

/// Phase-0 placeholder satisfying the Orchestrator's required `triage` argument
/// before the real Triage agent exists. It wakes for nothing and emits no
/// proposals, so `processInbox()` is a no-op until real agents are registered.
public struct NoopAgent: Agent {
    public init() {}
    public var id: String { "noop" }
    public var autonomy: Autonomy { .suggest }
    public func wakesFor(_ message: Message, context: AgentContext) -> Bool { false }
    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] { [] }
}
```

Create `SenaniApp/Sources/SenaniApp/Stubs/EngineAdapters.swift`:

```swift
import SenaniEngine
import SenaniGmail

/// Bridges the frozen `GmailSync` to the engine's `GmailSyncing` seam without
/// editing SenaniGmail. The method signatures already match
/// (`fetchMessages(query:maxResults:)`), so this is a marker conformance.
extension GmailSync: GmailSyncing {}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter noopAgentWakesForNothing
```

Expected: pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: NoopAgent triage placeholder + GmailSync GmailSyncing conformance"
```

(Append the standard trailer.)

---

### Task 5: AppEnvironment — the composition root (live + preview)

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/AppEnvironmentTests.swift` (append)

The pinned §3 composition root. It is the ONLY place stores/backends are constructed (§4.1). `preview()` is fully in-memory; `live()` is file-backed.

- [ ] **Step 1: Append failing tests to `AppEnvironmentTests.swift`**

Append to `SenaniApp/Tests/SenaniAppTests/AppEnvironmentTests.swift`:

```swift
import SenaniInference

@MainActor
@Test func previewBuildsACompleteGraph() async {
    let env = AppEnvironment.preview()
    // Every pinned member is constructed (the graph is complete).
    #expect(env.messages != nil)
    #expect(env.rules != nil)
    #expect(env.approvals != nil)
    // preview generator is the FakeTextGenerator: it never throws.
    let out = try? await env.generator.generate(prompt: "hi", maxTokens: 4)
    #expect(out != nil)
    // preview embedder returns a vector.
    let vec = try? await env.embedder.embed("hi")
    #expect(vec?.isEmpty == false)
}

@MainActor
@Test func liveBuildsAFileBackedGraphInATempDirectory() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("senani-live-\(UUID().uuidString)", isDirectory: true)
    let env = try AppEnvironment.live(base: tmp)
    // The live generator is NotReady until a model is picked: it throws.
    #expect(env.gmail != nil)
    // The DB file was created on disk.
    let dbPath = try AppSupport.databaseURL(base: tmp, fileManager: .default).path
    #expect(FileManager.default.fileExists(atPath: dbPath))
    try? FileManager.default.removeItem(at: tmp)
}

@MainActor
@Test func liveGeneratorIsNotReadyUntilModelPicked() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("senani-live-\(UUID().uuidString)", isDirectory: true)
    let env = try AppEnvironment.live(base: tmp)
    await #expect(throws: InferenceError.modelNotLoaded) {
        _ = try await env.generator.generate(prompt: "hi", maxTokens: 4)
    }
    try? FileManager.default.removeItem(at: tmp)
}
```

> The `!= nil` checks work because the members are non-optional value/reference types; the assertions exist to force construction of the whole graph (a failure to build any member throws or fails to compile). If the linter objects to `!= nil` on a non-optional, replace with a benign property read (e.g. `_ = env.messages`).

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter AppEnvironmentTests
```

Expected: failure — `AppEnvironment` undefined.

- [ ] **Step 3: Implement `AppEnvironment`**

Create `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`:

```swift
import Foundation
import SenaniStore
import SenaniInference
import SenaniGmail
import SenaniRules
import SenaniEngine

/// The composition root (reconciliation §3 / §4.1). The ONLY place stores and
/// backends are constructed. Screens receive these via @EnvironmentObject and
/// never build a store, backend, Keychain, or network client themselves.
@MainActor
public final class AppEnvironment: ObservableObject {
    public let database: SenaniDatabase
    public let messages: MessageStore
    public let rules: RuleStore
    public let approvals: ApprovalStore
    public let audit: PersistentAuditLog
    public let index: any VectorIndex          // SqliteVecIndex live; InMemoryVectorIndex preview
    public let generator: any TextGenerator    // NotReadyTextGenerator live; FakeTextGenerator preview
    public let embedder: any Embedder
    public let gmail: GmailAuth
    public let orchestrator: Orchestrator
    public let scheduler: Scheduler

    private init(database: SenaniDatabase, messages: MessageStore, rules: RuleStore,
                 approvals: ApprovalStore, audit: PersistentAuditLog, index: any VectorIndex,
                 generator: any TextGenerator, embedder: any Embedder, gmail: GmailAuth,
                 orchestrator: Orchestrator, scheduler: Scheduler) {
        self.database = database
        self.messages = messages
        self.rules = rules
        self.approvals = approvals
        self.audit = audit
        self.index = index
        self.generator = generator
        self.embedder = embedder
        self.gmail = gmail
        self.orchestrator = orchestrator
        self.scheduler = scheduler
    }

    // MARK: - Live (file-backed) graph

    /// Production graph. `base` defaults to the user's Application Support directory;
    /// tests pass a temp directory. The generator starts as NotReadyTextGenerator
    /// until the MLX picker plan injects a real MLXTextGenerator.
    public static func live(
        base: URL? = nil,
        clientID: String = liveClientID(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> AppEnvironment {
        let fm = FileManager.default
        let resolvedBase = try base ?? AppSupport.applicationSupportBase(fileManager: fm)
        let dbURL = try AppSupport.databaseURL(base: resolvedBase, fileManager: fm)

        let database = try SenaniDatabase.file(at: dbURL.path)
        let nowSeconds: @Sendable () -> Double = { now().timeIntervalSince1970 }

        let messages = MessageStore(database: database)
        let rules = RuleStore(database: database)
        let approvals = ApprovalStore(database: database, now: nowSeconds)
        let audit = PersistentAuditLog(database: database, now: nowSeconds)
        let index = SqliteVecIndex(database: database)
        let generator: any TextGenerator = NotReadyTextGenerator()
        let embedder: any Embedder = FakeEmbedder()   // MLXEmbedder injected by the picker plan

        let http = URLSessionHTTPClient()
        let tokenStore: any TokenStore = KeychainTokenStore()
        let gmail = GmailAuth(clientID: clientID, http: http, store: tokenStore, now: now)
        let accountEmail = ""   // populated by the onboarding plan after consent
        let mailBackend = GmailMailBackend(http: http, tokenProvider: gmail, accountEmail: accountEmail)
        let sync = GmailSync(http: http, tokenProvider: gmail, accountEmail: accountEmail)

        let (orchestrator, scheduler) = Self.makeEngine(
            mailBackend: mailBackend, approvals: approvals, audit: audit, messages: messages,
            index: index, embedder: embedder, rules: rules, sync: sync, now: now)

        return AppEnvironment(database: database, messages: messages, rules: rules,
                              approvals: approvals, audit: audit, index: index,
                              generator: generator, embedder: embedder, gmail: gmail,
                              orchestrator: orchestrator, scheduler: scheduler)
    }

    // MARK: - Preview (in-memory) graph

    /// In-memory graph for SwiftUI previews and UI tests: SenaniDatabase.inMemory(),
    /// InMemoryVectorIndex, app-local FakeTextGenerator/FakeEmbedder, InMemoryTokenStore.
    /// Needs no Keychain, MLX, or network.
    public static func preview(now: @escaping @Sendable () -> Date = Date.init) -> AppEnvironment {
        // Preview must never fail; an in-memory DB is the only fallible step.
        let database = (try? SenaniDatabase.inMemory()) ?? { fatalError("in-memory DB must build") }()
        let nowSeconds: @Sendable () -> Double = { now().timeIntervalSince1970 }

        let messages = MessageStore(database: database)
        let rules = RuleStore(database: database)
        let approvals = ApprovalStore(database: database, now: nowSeconds)
        let audit = PersistentAuditLog(database: database, now: nowSeconds)
        let index: any VectorIndex = InMemoryVectorIndex()
        let generator: any TextGenerator = FakeTextGenerator()
        let embedder: any Embedder = FakeEmbedder()

        let http = URLSessionHTTPClient()
        let tokenStore: any TokenStore = InMemoryTokenStore()
        let gmail = GmailAuth(clientID: "preview-client-id", http: http, store: tokenStore, now: now)
        let mailBackend = GmailMailBackend(http: http, tokenProvider: gmail, accountEmail: "preview@local")
        let sync = GmailSync(http: http, tokenProvider: gmail, accountEmail: "preview@local")

        let (orchestrator, scheduler) = Self.makeEngine(
            mailBackend: mailBackend, approvals: approvals, audit: audit, messages: messages,
            index: index, embedder: embedder, rules: rules, sync: sync, now: now)

        return AppEnvironment(database: database, messages: messages, rules: rules,
                              approvals: approvals, audit: audit, index: index,
                              generator: generator, embedder: embedder, gmail: gmail,
                              orchestrator: orchestrator, scheduler: scheduler)
    }

    // MARK: - Engine construction (SenaniEngine §3 contract)

    /// Builds the Orchestrator + Scheduler to the pinned SenaniEngine signatures.
    /// Phase 0 runs with NO agents: an empty registry and a NoopAgent triage, so
    /// processInbox() is a no-op until real agents (Triage/Reply-Drafter) register.
    private static func makeEngine(
        mailBackend: any MailBackend, approvals: ApprovalStore, audit: PersistentAuditLog,
        messages: MessageStore, index: any VectorIndex, embedder: any Embedder, rules: RuleStore,
        sync: GmailSync, now: @escaping @Sendable () -> Date
    ) -> (Orchestrator, Scheduler) {
        let registry = AgentRegistry(agents: [])
        let orchestrator = Orchestrator(
            registry: registry, triage: NoopAgent(), mailBackend: mailBackend,
            approvals: approvals, audit: audit, messages: messages, index: index,
            embedder: embedder, rules: rules, now: now)
        let scheduler = Scheduler(
            sync: sync, store: messages, orchestrator: orchestrator,
            interval: 300, now: now)
        return (orchestrator, scheduler)
    }

    /// Google OAuth desktop client ID (reconciliation §5 open item). Reads the
    /// SENANI_GOOGLE_CLIENT_ID env var; falls back to an obviously-fake placeholder
    /// so composition never fails. The onboarding plan wires the real value.
    private static func liveClientID() -> String {
        ProcessInfo.processInfo.environment["SENANI_GOOGLE_CLIENT_ID"]
            ?? "REPLACE_WITH_GOOGLE_OAUTH_DESKTOP_CLIENT_ID"
    }
}
```

> If `SenaniEngine`'s built `Orchestrator`/`Scheduler`/`AgentRegistry` initializers differ from §3, adapt `makeEngine` to the real signatures and record the deviation in the reconciliation doc in the same commit. Everything else (stores/Gmail/index/generator) is verified against real source and should compile as written.

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter AppEnvironmentTests
```

Expected: all pass (`previewBuildsACompleteGraph`, `liveBuildsAFileBackedGraphInATempDirectory`, `liveGeneratorIsNotReadyUntilModelPicked`, plus the Task-2 path test).

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: AppEnvironment composition root (live file-backed + preview in-memory graphs)"
```

(Append the standard trailer.)

---

### Task 6: Navigation skeleton — NavigationItem + placeholder destinations + RootScene

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/NavigationItem.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/Placeholders.swift`
- Create: `SenaniApp/Sources/SenaniApp/UI/RootScene.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/RootSceneSmokeTests.swift`

The top-level navigation skeleton: a sidebar (Inbox / Approvals / Activity / Settings) and placeholder destinations. Screens read the injected `AppEnvironment` via `@EnvironmentObject` — none constructs a store.

- [ ] **Step 1: Write a failing smoke test**

Create `SenaniApp/Tests/SenaniAppTests/RootSceneSmokeTests.swift`:

```swift
import Testing
import SwiftUI
@testable import SenaniApp

@MainActor
@Test func navigationItemsCoverTheFourSections() {
    #expect(NavigationItem.allCases == [.inbox, .approvals, .activity, .settings])
    #expect(NavigationItem.inbox.title == "Inbox")
    #expect(NavigationItem.settings.systemImage == "gearshape")
}

@MainActor
@Test func rootSceneInstantiatesWithPreviewEnvironment() {
    let env = AppEnvironment.preview()
    // Constructing the view tree with the injected environment must not crash.
    let root = RootScene().environmentObject(env)
    _ = root.body   // force the view body to evaluate
    #expect(env.selectedItem == .inbox)   // default selection
}
```

- [ ] **Step 2: Run to fail**

```
cd SenaniApp && swift test --filter RootSceneSmokeTests
```

Expected: failure — `NavigationItem` / `RootScene` / `AppEnvironment.selectedItem` undefined.

- [ ] **Step 3a: Add `selectedItem` to AppEnvironment**

In `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`, add a published selection so the sidebar binds through the composition root (still the single source of UI state):

```swift
    @Published public var selectedItem: NavigationItem = .inbox
```

(Add it just below the stored `let` properties, before `private init`.)

- [ ] **Step 3b: Implement `NavigationItem`**

Create `SenaniApp/Sources/SenaniApp/UI/NavigationItem.swift`:

```swift
import Foundation

/// The four top-level sections of the Phase-0 shell.
public enum NavigationItem: String, CaseIterable, Hashable, Identifiable, Sendable {
    case inbox, approvals, activity, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .approvals: return "Approvals"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: return "tray.and.arrow.down"
        case .approvals: return "checkmark.seal"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}
```

- [ ] **Step 3c: Implement placeholder destinations**

Create `SenaniApp/Sources/SenaniApp/UI/Placeholders.swift`:

```swift
import SwiftUI

/// Phase-0 placeholder destinations. Each reads the injected AppEnvironment to
/// prove the dependency reaches screens; the real cockpit/queue/log/settings
/// screens are separate plans.
struct InboxPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Inbox",
                        detail: "No messages yet. Connect Gmail and pick a model to begin.")
    }
}

struct ApprovalsPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Approvals",
                        detail: "Proposals awaiting your approval will appear here.")
    }
}

struct ActivityPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Activity",
                        detail: "An audit trail of every action runs here.")
    }
}

struct SettingsPlaceholder: View {
    @EnvironmentObject private var env: AppEnvironment
    var body: some View {
        PlaceholderBody(title: "Settings",
                        detail: "Account, model, and autonomy settings.")
    }
}

private struct PlaceholderBody: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.largeTitle.bold())
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
```

- [ ] **Step 3d: Implement `RootScene`**

Create `SenaniApp/Sources/SenaniApp/UI/RootScene.swift`:

```swift
import SwiftUI

/// Top-level navigation skeleton: a sidebar of the four sections plus the
/// selected placeholder destination. Selection lives on AppEnvironment so the
/// composition root remains the single source of state.
struct RootScene: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: Binding(
                get: { env.selectedItem },
                set: { env.selectedItem = $0 ?? .inbox }
            )) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .navigationTitle("Senani")
        } detail: {
            destination(for: env.selectedItem)
        }
    }

    @ViewBuilder
    private func destination(for item: NavigationItem) -> some View {
        switch item {
        case .inbox: InboxPlaceholder()
        case .approvals: ApprovalsPlaceholder()
        case .activity: ActivityPlaceholder()
        case .settings: SettingsPlaceholder()
        }
    }
}

#Preview {
    RootScene().environmentObject(AppEnvironment.preview())
}
```

- [ ] **Step 4: Run to pass**

```
cd SenaniApp && swift test --filter RootSceneSmokeTests
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: navigation skeleton (NavigationItem + placeholders + RootScene) injecting AppEnvironment"
```

(Append the standard trailer.)

---

### Task 7: App entry point — @main wiring live() with preview fallback

**Files:**
- Modify: `SenaniApp/Sources/SenaniApp/SenaniApp.swift`
- Test: covered by `RootSceneSmokeTests` (no new test; the entry point is verified by the suite compiling + the smoke test).

Replace the ad-hoc `AppState` entry point with one that builds the live graph and injects `AppEnvironment` via `@EnvironmentObject`. If `live()` throws (e.g. DB cannot open), fall back to `preview()` so the app still launches and surfaces the error in-app later (a separate plan owns the error UI).

- [ ] **Step 1: Replace `SenaniApp.swift`**

Replace `SenaniApp/Sources/SenaniApp/SenaniApp.swift` entirely:

```swift
import SwiftUI

/// App entry point. Builds the live composition root once and injects it into
/// the view tree. The single @main App is the executable target's entry point —
/// do NOT add a main.swift.
@main
struct SenaniApp: App {
    @StateObject private var environment: AppEnvironment

    init() {
        // Composition Root: construct the live graph once. If it fails (e.g. the
        // database cannot be opened), fall back to an in-memory preview graph so
        // the window still appears; the dedicated error/onboarding plan surfaces
        // the failure to the user.
        let env: AppEnvironment
        do {
            env = try AppEnvironment.live()
        } catch {
            env = AppEnvironment.preview()
        }
        _environment = StateObject(wrappedValue: env)
    }

    var body: some Scene {
        WindowGroup {
            RootScene()
                .environmentObject(environment)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}
```

- [ ] **Step 2: Run to fail / build**

```
cd SenaniApp && swift build
```

Expected at this point: the build may still fail because the OLD files `UI/MainNavigationView.swift`, `UI/DetailView.swift`, `UI/Theme.swift` still reference the removed `AppState`/`NavigationItem` old shape. That is resolved in Task 8. (If they happen to still compile, the build passes — proceed.)

- [ ] **Step 3: (handled in Task 8)**

The entry point is complete; the remaining compile errors are stale files removed next.

- [ ] **Step 4: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: @main entry point injects live() AppEnvironment with preview fallback"
```

(Append the standard trailer.)

---

### Task 8: Remove obsolete scaffold + full suite green + run smoke

**Files:**
- Delete: `SenaniApp/Sources/SenaniApp/UI/MainNavigationView.swift`
- Delete: `SenaniApp/Sources/SenaniApp/UI/DetailView.swift`
- Delete: `SenaniApp/Sources/SenaniApp/UI/Theme.swift`

These predate the pinned contract: `MainNavigationView`/`SidebarView`/`ContentView` use the old `AppState` + 5-case `NavigationItem`; `DetailView` hard-codes a fake message; `Theme.swift` defines ad-hoc `senaniGold`/`goldGlass` that belong to the DesignSystem plan, not here. Removing them leaves `RootScene` as the sole navigation surface.

- [ ] **Step 1: Delete the stale files**

```
cd SenaniApp && git rm Sources/SenaniApp/UI/MainNavigationView.swift Sources/SenaniApp/UI/DetailView.swift Sources/SenaniApp/UI/Theme.swift
```

- [ ] **Step 2: Build clean**

```
cd SenaniApp && swift build
```

Expected: builds with no errors and no strict-concurrency warnings. Resolve any `Sendable`/actor-isolation warnings before finishing (the composition root is `@MainActor`; `live()`/`preview()` are `@MainActor static` so they may freely touch `@MainActor` state).

- [ ] **Step 3: Run the entire test suite**

```
cd SenaniApp && swift test
```

Expected: ALL tests pass across `StubsTests`, `AppEnvironmentTests`, `RootSceneSmokeTests`.

- [ ] **Step 4: Smoke-run the executable headlessly**

```
cd SenaniApp && swift build --product SenaniApp
```

Expected: a `SenaniApp` executable is produced. (A full `swift run SenaniApp` opens a window and requires a GUI session; in a headless worktree, a successful `swift build --product SenaniApp` is the reproducible proof that the app target links and the `@main` scene compiles. Note this in the PR.)

- [ ] **Step 5: Final commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: remove obsolete AppState scaffold; full app-shell suite green"
```

(Append the standard trailer.)

---

## Self-Review

**Goal requirement → task mapping:**

- **CLI-reproducible macOS app target depending on all 9 packages + SenaniEngine** → Task 1 (manifest: tools 6.0, all 10 path deps, executable + test targets, strict concurrency). Decision justified in "Why SwiftPM executable" (reproducible `swift build`/`run`/`test`, native local package graph, deferred `.app` packaging). ✅
- **`AppEnvironment` EXACTLY per §3** (`@MainActor final class … : ObservableObject`; members `database, messages, rules, approvals, audit, index, generator, embedder, gmail, orchestrator, scheduler`; `live() throws` file-backed in Application Support; `preview()` in-memory with `SenaniDatabase.inMemory()`, `InMemoryVectorIndex`, local `FakeTextGenerator`, `InMemoryTokenStore`) → Task 5 (+ Task 2 for the App Support path, Task 3 for the fakes). ✅
- **Live `generator` is a `NotReadyTextGenerator` stub until the MLX picker selects a model** → Task 3 defines the stub; Task 5 wires it into `live()`; `liveGeneratorIsNotReadyUntilModelPicked` test asserts it throws `.modelNotLoaded`. ✅
- **App lifecycle: scene/window + sidebar (Inbox/Approvals/Activity/Settings) + placeholder destinations + `@EnvironmentObject` injection** → Task 6 (`NavigationItem`, `Placeholders`, `RootScene`) + Task 7 (`@main` injects via `.environmentObject`). ✅
- **Test: `preview()` builds a complete graph** → Task 5 `previewBuildsACompleteGraph`. **Smoke test: App target compiles + root scene instantiates with preview env** → Task 6 `rootSceneInstantiatesWithPreviewEnvironment` + Task 8 `swift build --product SenaniApp`. ✅
- **§4.1 honored: composition root is the ONLY place stores/backends are constructed** → all construction lives in `AppEnvironment.live()/preview()`; placeholder screens take `@EnvironmentObject` and construct nothing (Tasks 5, 6). ✅
- **Detail where SenaniEngine's `Orchestrator`/`Scheduler` are constructed in `live()`** → Task 5 `makeEngine` builds both to the §3 contract with an empty `AgentRegistry` + `NoopAgent` triage (Task 4); the build-order dependency on the not-yet-built `SenaniEngine` is flagged in Cross-package assumptions and as a blocking prerequisite in Task 1. ✅

**Verified deviations from the reconciliation doc (coded to real source, flagged for the human):**
1. `SenaniDatabase` is `@unchecked Sendable` (doc said `Sendable`) — immaterial to the wiring.
2. `ApprovalStore.init(database:, now:)` and `PersistentAuditLog.init(database:, now:)` REQUIRE a `now:` closure (doc §2 listed `init(database:)`); `live()`/`preview()` pass `{ now().timeIntervalSince1970 }`.
3. `SqliteVecIndex.init(database:, namespace:)` (not parameterless) — `live()` passes the live `database`.
4. `GmailAuth.init(clientID:, http:, store:, now:)` — `live()` reads the client ID from `SENANI_GOOGLE_CLIENT_ID` with a placeholder fallback (reconciliation §5 open item).
5. **`SenaniInference` ships NO `FakeTextGenerator`/in-memory `Embedder`** — both are defined app-local in Task 3 (the reconciliation §3 phrase "a local FakeTextGenerator" is honored literally). The live `embedder` is also `FakeEmbedder` until the MLX picker injects `MLXEmbedder`.
6. **`SenaniEngine` does not exist yet** — Task 1 records the hard build-order prerequisite; `NoopAgent`/`makeEngine` are coded to the §3 pinned signatures and adapt to the built API if it differs.

**Explicitly deferred to separate plans:** DesignSystem (gold-glass tokens — old `Theme.swift` removed in Task 8); MLX model picker/downloader (swaps `NotReadyTextGenerator`→`MLXTextGenerator` and `FakeEmbedder`→`MLXEmbedder`); Gmail OAuth onboarding UI (real client ID + consent + `accountEmail`); real Inbox/Approvals/Activity/Settings screens; Triage/Reply-Drafter agents (register into the currently-empty `AgentRegistry`); notarized `.app` packaging (Deferred phase).
