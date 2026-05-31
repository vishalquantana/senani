# Auto-Update (Sparkle) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship privacy-respecting in-app automatic updates for the Senani macOS app (Roadmap **Deferred → Auto-update**). Integrate **Sparkle 2** into the `SenaniApp/` build, add a minimal **"Check for Updates…"** menu item, and ship a **signed appcast** (`appcast.xml` with EdDSA signatures) hosted at a human-supplied feed URL that delivers the **signed + notarized** `.app` produced by the code-signing plan. All telemetry/system-profiling is **disabled** per `docs/ARCHITECTURE.md` (no telemetry, no accounts). A pure, unit-tested `UpdateDecision` view-model encapsulates version-compare / update-offer logic; the Sparkle wiring itself is verified by documented manual steps with expected output.

**Architecture:** Sparkle 2 is added as a SwiftPM dependency of the `SenaniApp` executable target. A small `Updates/` module holds: (1) `UpdateConfiguration` — the static Sparkle settings (feed URL, EdDSA public key, profiling OFF, automatic-check opt-in) surfaced both to `Info.plist` (when bundled as a `.app`) and to a programmatic `SPUUpdaterDelegate`; (2) `UpdateController` — a thin `@MainActor` wrapper around Sparkle's `SPUStandardUpdaterController` that exposes a `checkForUpdates()` the menu calls and that **forces system-profiling off** in code (belt-and-suspenders against the plist); (3) `UpdateDecision` — a **pure, Sparkle-free** value type that decides, given a current version and a parsed feed item, whether an update should be offered. The pure decision logic is the only unit-tested surface; the SPU glue is conditionally compiled so `swift test` (no `.app` bundle, no Sparkle.framework on CI's headless build) still passes. Updates flow: CI/`Scripts/release.sh` builds → calls the **code-signing plan's** `Scripts/codesign.sh` to sign → notarizes/staples → zips → `generate_appcast` produces EdDSA-signed `appcast.xml` → publish zip + appcast to the feed host. The shipped `.app` is the signed+notarized artifact; Sparkle verifies both the EdDSA signature (key in appcast) and the Apple code signature on install.

> **Hard dependency:** this plan **depends on `docs/superpowers/plans/2026-05-31-code-signing-and-notarization.md`** (a sibling Deferred plan). That plan owns Developer ID signing, notarization/stapling, the `.app` bundling of the SwiftPM-executable `SenaniApp` target (Info.plist + entitlements), and `Scripts/codesign.sh` + `Scripts/notarize.sh`. This plan **calls** those scripts; it does not re-implement signing. If that plan has not landed, the infra tasks here are **blocked** at the "build a signable `.app`" step — Tasks 1–4 (Sparkle integration + pure decision logic + menu) are NOT blocked and can land first.

**Tech Stack:** Swift 6.2 (strict concurrency, `swift-tools-version: 6.0`), Swift Package Manager (executable product), SwiftUI, Swift Testing (`import Testing`, ships with the toolchain). Sparkle **2.6.x** via SwiftPM. macOS 14+, Apple Silicon. Appcast tooling: Sparkle's `generate_appcast` + `generate_keys` (Homebrew `sparkle` or the release artifacts). Feed hosting: any static HTTPS host (human input).

**Working directory:** All `swift` commands run from the repo-root `SenaniApp/` directory unless stated otherwise. Shell scripts live at repo-root `Scripts/`. CI lives at `.github/workflows/release.yml`.

---

## Human inputs (flag before coding — NEVER commit secrets)

| Input | What it is | Where it goes | Notes |
|-------|-----------|---------------|-------|
| **`SUFeedURL`** | The HTTPS URL where `appcast.xml` is hosted (e.g. `https://updates.senani.app/appcast.xml`). | `Info.plist` `SUFeedURL` + `UpdateConfiguration.feedURL`. | Public, but environment-specific. Stored as the CI variable `SENANI_SU_FEED_URL` and substituted into the Info.plist at package time. Placeholder `https://updates.example.invalid/appcast.xml` is used in code until the human supplies the real one. |
| **`SUPublicEDKey`** | The Sparkle EdDSA **public** key (base64), output of `generate_keys`. | `Info.plist` `SUPublicEDKey` + `UpdateConfiguration.publicEDKey`. | Public — safe to commit. Pairs with the private key below. |
| **Sparkle EdDSA private key** | The signing key Sparkle's `generate_appcast` uses to sign each update. Lives **in the macOS Keychain** (Sparkle's default, account `ed25519`) on the release machine, OR exported as a base64 secret for CI. | CI secret `SENANI_SPARKLE_ED_PRIVATE_KEY`; never in the repo. | Generated once by `generate_keys`. **NEVER committed.** If lost, all future updates must be re-keyed and existing installs can't auto-update — back it up offline. |
| **Code-signing identity / notarization profile** | Owned by the code-signing plan (Developer ID Application cert + `notarytool` keychain profile / App Store Connect API key). | Consumed by `Scripts/codesign.sh` + `Scripts/notarize.sh`. | This plan only *calls* those scripts. |
| **Feed host write credentials** | Whatever the static host needs to publish (`rsync`/`scp` key, S3 creds, or GitHub Pages push token). | CI secret(s), e.g. `SENANI_UPDATES_DEPLOY_KEY`. | Publish step is parameterized; default implementation pushes to a `gh-pages`-style `updates/` path. |

> **Privacy guarantee (ARCHITECTURE):** Senani has no telemetry and no accounts. Sparkle's anonymous **system profiling** (`SUEnableSystemProfiling`) sends OS version / CPU / app stats to the feed host on every check. We set it to `NO` in the plist **and** force `false` via `SPUUpdaterDelegate.allowedSystemProfileKeys`/`updater(_:shouldPostHistogramTo:)` so a misconfigured plist can never leak. Automatic update checks are **opt-in** (`SUEnableAutomaticChecks` is NOT set to YES by default; the user enables it). The only network hop Sparkle makes is a GET of the feed URL the user's own app is configured for — consistent with the "your own account is the only network hop" model.

---

## File Structure

```
SenaniApp/
  Package.swift                                  # + Sparkle dependency (EDIT)
  Sources/SenaniApp/
    Updates/
      UpdateConfiguration.swift                  # static feed URL + public key + privacy flags (pure)
      UpdateDecision.swift                        # PURE version-compare / offer logic (unit-tested, no Sparkle)
      SemanticVersion.swift                       # PURE Sparkle-style version parse + compare (unit-tested)
      UpdateController.swift                      # @MainActor SPUStandardUpdaterController wrapper (#if canImport(Sparkle))
      UpdaterPrivacyDelegate.swift               # SPUUpdaterDelegate: forces profiling OFF (#if canImport(Sparkle))
    UI/
      CheckForUpdatesCommand.swift               # SwiftUI Commands: "Check for Updates…" menu item
    SenaniApp.swift                              # + .commands { CheckForUpdatesCommand(...) } (EDIT)
  Tests/SenaniAppTests/
    SemanticVersionTests.swift                   # parse + ordering + malformed
    UpdateDecisionTests.swift                    # newer→offer, same/older→none, malformed feed→none

Packaging/
  Senani-Info.plist.template                     # Info.plist with Sparkle keys + ${SU_FEED_URL}/${SU_PUBLIC_ED_KEY} substitution slots

Scripts/
  release.sh                                     # build → sign → notarize → appcast (sign) → publish (NEW)
  sign_appcast.sh                                # wraps generate_appcast with the EdDSA key (NEW)
```

> The code-signing plan owns `Packaging/` bundling (turning the SwiftPM executable into `Senani.app`), `Scripts/codesign.sh`, and `Scripts/notarize.sh`. This plan **adds** the Sparkle keys to the Info.plist template (Task 5) and the appcast/release scripts (Tasks 6–8). If the code-signing plan has already created `Packaging/Senani-Info.plist.template`, **edit** it to add the Sparkle keys rather than creating a new one.

---

## Why Sparkle 2 (not a hand-rolled appcast)

Recorded so dependents don't relitigate it:

- **Mature, audited, the macOS standard.** Sparkle handles the hard, security-critical parts we'd otherwise hand-roll badly: atomic download-verify-replace, **EdDSA signature verification** of each update, Apple **code-signature continuity** checks (refuses to install an update signed by a different Developer ID), delta updates, and the installer-launcher XPC dance that survives app-quit. A hand-rolled "download a dmg and `mv` it" loses every one of these and is a supply-chain risk.
- **Privacy is configurable to zero.** Sparkle's only mandatory network call is the GET of the feed we point it at; profiling/metrics are explicit opt-in flags we turn OFF. A hand-rolled updater would still need to fetch *some* feed — Sparkle just does it correctly and offline-friendly.
- **EdDSA signing is first-class.** `generate_keys` + `generate_appcast` produce a signed `appcast.xml` in one command; the public key sits in `Info.plist`. Rolling this ourselves (signing, key storage, verification on-device) is exactly the code most likely to have an exploitable bug.
- **Cost we accept:** Sparkle requires a real `.app` bundle (Info.plist + the embedded `Sparkle.framework` + the XPC `Installer`/`Autoupdate` helpers) — it cannot run from a bare `swift run` executable. This is the **bundling dependency on the code-signing plan**, which already has to produce a signed `.app`. The pure `UpdateDecision`/`SemanticVersion` logic is extracted so it's testable headlessly without any of that.

---

## Tasks

### Task 1 — Add the Sparkle SwiftPM dependency

- [ ] **1.1** Edit `SenaniApp/Package.swift` to bump tools version and add Sparkle. Replace the file's `dependencies` and target wiring:

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
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
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
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "SenaniAppTests",
            dependencies: ["SenaniApp"]
        ),
    ]
)
```

- [ ] **1.2** Resolve and confirm Sparkle is pinned.

```bash
swift package --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp resolve
swift package --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp show-dependencies --format flat | grep -i sparkle
```
Expected output (version may differ in patch):
```
sparkle<https://github.com/sparkle-project/Sparkle@2.6.x>
```

> If the test target already exists from the app-shell plan, do not duplicate it — merge the Sparkle product into the existing `executableTarget` and keep the existing `testTarget` name. Verify with `swift package describe | grep -A2 Tests`.

---

### Task 2 — Pure `SemanticVersion` (TDD)

The pure version comparator. Sparkle internally uses `SUStandardVersionComparator`; we mirror its "numeric components, longer-with-extra-zeros-equal, prerelease < release" behavior for the parts our feed uses, and keep it Sparkle-free so it's unit-testable on CI.

- [ ] **2.1** Write the failing tests `SenaniApp/Tests/SenaniAppTests/SemanticVersionTests.swift`:

```swift
import Testing
@testable import SenaniApp

struct SemanticVersionTests {
    @Test func parsesDottedComponents() throws {
        let v = try #require(SemanticVersion("1.4.2"))
        #expect(v.components == [1, 4, 2])
    }

    @Test func equalWhenTrailingZeros() throws {
        let a = try #require(SemanticVersion("1.4"))
        let b = try #require(SemanticVersion("1.4.0"))
        #expect(a == b)
    }

    @Test func ordersNumerically() throws {
        let older = try #require(SemanticVersion("1.9.0"))
        let newer = try #require(SemanticVersion("1.10.0"))   // 10 > 9, not string order
        #expect(older < newer)
    }

    @Test func rejectsEmptyOrNonNumeric() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("abc") == nil)
        #expect(SemanticVersion("1.x.0") == nil)
    }
}
```

- [ ] **2.2** Run — confirm it FAILS to compile (type missing):
```bash
swift test --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp --filter SemanticVersionTests 2>&1 | tail -5
```
Expected: a compile error `cannot find 'SemanticVersion' in scope`.

- [ ] **2.3** Implement `SenaniApp/Sources/SenaniApp/Updates/SemanticVersion.swift`:

```swift
import Foundation

/// Pure, Sparkle-free numeric version. Mirrors the subset of
/// `SUStandardVersionComparator` behavior our appcast uses: dot-separated
/// numeric components, where trailing zeros are insignificant (1.4 == 1.4.0).
public struct SemanticVersion: Equatable, Comparable, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part) else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        normalized(lhs.components) == normalized(rhs.components)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let l = lhs.components, r = rhs.components
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// Drops insignificant trailing zeros so 1.4 and 1.4.0 compare equal.
    private static func normalized(_ c: [Int]) -> [Int] {
        var out = c
        while out.count > 1, out.last == 0 { out.removeLast() }
        return out
    }
}
```

- [ ] **2.4** Run — confirm PASS:
```bash
swift test --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp --filter SemanticVersionTests 2>&1 | tail -5
```
Expected: `Test run with N tests passed`.

- [ ] **2.5** Commit: `feat(updates): pure SemanticVersion comparator with tests`.

---

### Task 3 — Pure `UpdateDecision` (TDD)

Encapsulates "given the current app version and a parsed feed item, do we offer an update?" — the testable glue. Feed parsing is modeled as an explicit input so a *malformed* feed maps to `nil` item → no update.

- [ ] **3.1** Write failing tests `SenaniApp/Tests/SenaniAppTests/UpdateDecisionTests.swift`:

```swift
import Testing
@testable import SenaniApp

struct UpdateDecisionTests {
    @Test func offersWhenFeedIsNewer() {
        let item = FeedItem(version: "1.5.0", title: "Senani 1.5.0", url: "https://updates.example.invalid/Senani-1.5.0.zip")
        let d = UpdateDecision.evaluate(currentVersion: "1.4.2", feedItem: item)
        #expect(d == .updateAvailable(item))
    }

    @Test func noUpdateWhenSameVersion() {
        let item = FeedItem(version: "1.4.2", title: "Senani 1.4.2", url: "https://updates.example.invalid/Senani-1.4.2.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.2", feedItem: item) == .upToDate)
    }

    @Test func noUpdateWhenFeedIsOlder() {
        let item = FeedItem(version: "1.3.9", title: "Senani 1.3.9", url: "https://updates.example.invalid/Senani-1.3.9.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.0", feedItem: item) == .upToDate)
    }

    @Test func malformedFeedVersionMeansNoUpdate() {
        let item = FeedItem(version: "not-a-version", title: "broken", url: "https://x.invalid/a.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.0", feedItem: item) == .unreadableFeed)
    }

    @Test func malformedCurrentVersionMeansNoUpdate() {
        let item = FeedItem(version: "2.0.0", title: "ok", url: "https://x.invalid/a.zip")
        #expect(UpdateDecision.evaluate(currentVersion: "", feedItem: item) == .unreadableFeed)
    }

    @Test func nilFeedItemMeansNoUpdate() {
        #expect(UpdateDecision.evaluate(currentVersion: "1.4.0", feedItem: nil) == .unreadableFeed)
    }
}
```

- [ ] **3.2** Run — confirm FAILS to compile:
```bash
swift test --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp --filter UpdateDecisionTests 2>&1 | tail -5
```
Expected: `cannot find 'FeedItem' / 'UpdateDecision' in scope`.

- [ ] **3.3** Implement `SenaniApp/Sources/SenaniApp/Updates/UpdateDecision.swift`:

```swift
import Foundation

/// A single appcast `<item>` reduced to the fields the decision needs.
/// (In production Sparkle parses the XML; in tests we construct it directly.)
public struct FeedItem: Equatable, Sendable {
    public let version: String       // the `sparkle:version` / shortVersionString
    public let title: String
    public let url: String           // enclosure URL of the .zip/.dmg
    public init(version: String, title: String, url: String) {
        self.version = version
        self.title = title
        self.url = url
    }
}

/// Pure update-offer decision. No Sparkle, no I/O — fully unit-testable.
public enum UpdateDecision: Equatable, Sendable {
    case updateAvailable(FeedItem)
    case upToDate
    case unreadableFeed   // malformed feed item or unparseable current version

    public static func evaluate(currentVersion: String, feedItem: FeedItem?) -> UpdateDecision {
        guard let item = feedItem else { return .unreadableFeed }
        guard let current = SemanticVersion(currentVersion),
              let candidate = SemanticVersion(item.version) else {
            return .unreadableFeed
        }
        return candidate > current ? .updateAvailable(item) : .upToDate
    }
}
```

- [ ] **3.4** Run — confirm PASS:
```bash
swift test --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp --filter UpdateDecisionTests 2>&1 | tail -5
```
Expected: all `UpdateDecisionTests` pass.

- [ ] **3.5** Commit: `feat(updates): pure UpdateDecision offer logic with tests`.

---

### Task 4 — Sparkle config + privacy delegate + controller + menu

This is the SPU glue. It is **conditionally compiled** on `canImport(Sparkle)` so the package still type-checks if Sparkle is unavailable on a given runner, and so the pure tests in Tasks 2–3 never need the framework.

- [ ] **4.1** `SenaniApp/Sources/SenaniApp/Updates/UpdateConfiguration.swift` (pure — no Sparkle import):

```swift
import Foundation

/// Single source of truth for Sparkle settings. The same values appear in the
/// app's Info.plist (consumed by Sparkle at runtime) and here (used to assert /
/// override at startup). PRIVACY: profiling is OFF and automatic checks are
/// opt-in, per docs/ARCHITECTURE.md (no telemetry, no accounts).
public enum UpdateConfiguration {
    /// Human input: real value supplied at package time. Placeholder until then.
    public static let feedURL = "https://updates.example.invalid/appcast.xml"

    /// Human input: base64 EdDSA public key from `generate_keys`. Placeholder.
    public static let publicEDKey = "REPLACE_WITH_SUPublicEDKey_FROM_generate_keys"

    /// PRIVACY FLAGS — must match Info.plist and are re-enforced in code.
    public static let systemProfilingEnabled = false      // SUEnableSystemProfiling = NO
    public static let automaticChecksOptIn   = false      // user opts in; not forced YES
    public static let sendsAnonymousMetrics  = false      // never
}
```

- [ ] **4.2** `SenaniApp/Sources/SenaniApp/Updates/UpdaterPrivacyDelegate.swift`:

```swift
#if canImport(Sparkle)
import Foundation
import Sparkle

/// Belt-and-suspenders privacy: even if Info.plist were misconfigured, this
/// delegate guarantees Sparkle posts NO system-profile data to the feed host.
final class UpdaterPrivacyDelegate: NSObject, SPUUpdaterDelegate {
    /// Returning an empty array means Sparkle appends no profile parameters to
    /// the feed request. (Combined with SUEnableSystemProfiling = NO.)
    func feedParameters(for updater: SPUUpdater,
                        sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        return []
    }

    /// Refuse profiling regardless of caller.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
}
#endif
```

> **Sparkle 2 API note:** the profile-suppression hook is `feedParameters(for:sendingSystemProfile:)` returning `[]`, plus `SUEnableSystemProfiling = NO` in the plist. If the linked Sparkle version renames this, keep the contract — return no parameters — and record the deviation here. Sparkle does not send profiling when `sendingProfile` is false and no extra params are supplied.

- [ ] **4.3** `SenaniApp/Sources/SenaniApp/Updates/UpdateController.swift`:

```swift
#if canImport(Sparkle)
import Foundation
import Sparkle
import Combine

/// @MainActor wrapper around Sparkle's standard updater. The "Check for
/// Updates…" menu binds to this. Profiling is forced off via the delegate;
/// automatic checks remain user opt-in.
@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private let privacyDelegate = UpdaterPrivacyDelegate()

    /// `canCheckForUpdates` drives the menu item's enabled state.
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: privacyDelegate,
            userDriverDelegate: nil
        )
        // Enforce privacy in code (do not rely on plist alone).
        controller.updater.sendsSystemProfile = false
        // Honor opt-in: do not flip automaticallyChecksForUpdates to true here.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#else
import Foundation
/// Headless / no-Sparkle fallback so the package type-checks on runners without
/// the framework (e.g. CI running `swift test`). The menu item is disabled.
@MainActor
final class UpdateController: ObservableObject {
    @Published var canCheckForUpdates = false
    init() {}
    func checkForUpdates() {}
}
#endif
```

- [ ] **4.4** `SenaniApp/Sources/SenaniApp/UI/CheckForUpdatesCommand.swift`:

```swift
import SwiftUI

/// Adds a single "Check for Updates…" item to the app menu, bound to the
/// shared UpdateController. Disabled while Sparkle is mid-check or unavailable.
struct CheckForUpdatesCommand: Commands {
    @ObservedObject var updateController: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
        }
    }
}
```

- [ ] **4.5** Wire it into `SenaniApp/Sources/SenaniApp/SenaniApp.swift`. Add the controller as state and attach `.commands`:

```swift
@main
struct SenaniApp: App {
    @State private var appState: AppState
    @StateObject private var updateController = UpdateController()

    // ... existing init() unchanged ...

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.authManager.isAuthenticated {
                    MainNavigationView()
                } else {
                    OnboardingView()
                }
            }
            .environment(appState)
            .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CheckForUpdatesCommand(updateController: updateController)
        }
    }
}
```

> If the app-shell plan has migrated `SenaniApp` to inject `AppEnvironment` instead of `AppState`, keep the `updateController` as a separate `@StateObject` exactly as above — the update controller is independent of the engine graph and the menu wiring is unchanged.

- [ ] **4.6** Build to confirm the glue compiles (Sparkle present):
```bash
swift build --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp 2>&1 | tail -15
```
Expected: `Build complete!` (Sparkle.framework links; may take longer on first resolve).

- [ ] **4.7** Re-run the full test target to confirm pure tests still pass alongside the SPU glue:
```bash
swift test --package-path /Users/vishalkumar/Downloads/qmail/SenaniApp 2>&1 | tail -5
```
Expected: all tests pass (only `SemanticVersionTests` + `UpdateDecisionTests` exist; SPU glue has no unit tests by design).

- [ ] **4.8** Commit: `feat(updates): Sparkle controller, privacy delegate, Check-for-Updates menu`.

---

### Task 5 — Info.plist Sparkle keys (privacy-locked)

The `.app` bundling is owned by the code-signing plan. This task adds the Sparkle keys to its Info.plist template (or creates the template if that plan hasn't yet).

- [ ] **5.1** Create/edit `Packaging/Senani-Info.plist.template` to include the Sparkle block. If the file exists, insert the keys below into the top-level `<dict>`; if not, this is the minimum viable template (the code-signing plan extends it with bundle id, version, entitlements):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Senani</string>
    <key>CFBundleIdentifier</key>      <string>app.senani.Senani</string>
    <key>CFBundleShortVersionString</key> <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>

    <!-- ===== Sparkle auto-update (privacy-locked) ===== -->
    <key>SUFeedURL</key>               <string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key>           <string>${SU_PUBLIC_ED_KEY}</string>

    <!-- Privacy: NO anonymous system profiling / metrics (docs/ARCHITECTURE.md). -->
    <key>SUEnableSystemProfiling</key> <false/>

    <!-- Automatic checks are USER OPT-IN: do NOT force-enable. Sparkle will
         prompt on first launch; default stays off until the user agrees. -->
    <key>SUEnableAutomaticChecks</key> <false/>

    <!-- Required for Sparkle 2 sandboxed/installer flow on a signed .app. -->
    <key>SUEnableInstallerLauncherService</key> <true/>

    <!-- 24h is fine when the user opts in; not used while checks are off. -->
    <key>SUScheduledCheckInterval</key> <integer>86400</integer>
</dict>
</plist>
```

> **Exact privacy keys to set (documented per the SCOPE):** `SUEnableSystemProfiling = NO`, `SUEnableAutomaticChecks = NO` (opt-in), `SUFeedURL = ${SU_FEED_URL}` (human input), `SUPublicEDKey = ${SU_PUBLIC_ED_KEY}` (human input), `SUEnableInstallerLauncherService = YES` (Sparkle 2 install flow). `${...}` slots are substituted at package time from CI variables (Task 7) — the placeholders are never the shipped values.

- [ ] **5.2** Validate the template is well-formed XML:
```bash
plutil -lint /Users/vishalkumar/Downloads/qmail/Packaging/Senani-Info.plist.template
```
Expected: `.../Senani-Info.plist.template: OK` (plutil tolerates the `${...}` tokens as string content).

- [ ] **5.3** Commit: `chore(updates): Info.plist Sparkle keys, profiling disabled`.

---

### Task 6 — EdDSA keys + the appcast signing script

- [ ] **6.1** **(Human, one-time)** Generate the Sparkle EdDSA keypair. Install Sparkle's tools and run `generate_keys`:
```bash
brew install --cask sparkle           # or download Sparkle-2.6.x.tar.xz and use bin/
"$(brew --prefix)/Caskroom/sparkle/"*/bin/generate_keys
```
Expected output (the **public** key is printed; the **private** key is stored in the login Keychain):
```
A key has been generated and saved in your keychain. Add the public key
(pubkey) to the SUPublicEDKey key of your app's Info.plist:

<key>SUPublicEDKey</key>
<string>aBcD…base64…XyZ=</string>
```
Action: paste the base64 into `UpdateConfiguration.publicEDKey` and the CI var `SENANI_SU_PUBLIC_ED_KEY`. For CI signing, export the private key for the secret:
```bash
"$(brew --prefix)/Caskroom/sparkle/"*/bin/generate_keys -x /tmp/sparkle_priv_key.txt   # base64 private key
# Store the contents of /tmp/sparkle_priv_key.txt as CI secret SENANI_SPARKLE_ED_PRIVATE_KEY, then shred it.
```

- [ ] **6.2** Create `Scripts/sign_appcast.sh` — wraps `generate_appcast`, signing every `.zip`/`.dmg` in a release dir and emitting `appcast.xml`:

```bash
#!/usr/bin/env bash
# Signs all updates in a release directory and (re)generates a signed appcast.xml.
# Uses the Sparkle EdDSA private key from the login Keychain (local) or from
# the env var SENANI_SPARKLE_ED_PRIVATE_KEY (CI). NEVER prints the key.
set -euo pipefail

RELEASE_DIR="${1:?usage: sign_appcast.sh <release-dir> [feed-url]}"
FEED_URL="${2:-${SENANI_SU_FEED_URL:-https://updates.example.invalid/appcast.xml}}"

# Locate generate_appcast from the installed Sparkle cask, or PATH.
GEN_APPCAST="$(command -v generate_appcast || true)"
if [[ -z "${GEN_APPCAST}" ]]; then
  GEN_APPCAST="$(ls "$(brew --prefix)"/Caskroom/sparkle/*/bin/generate_appcast 2>/dev/null | head -1 || true)"
fi
[[ -n "${GEN_APPCAST}" ]] || { echo "error: generate_appcast not found (brew install --cask sparkle)"; exit 1; }

# On CI, materialize the private key into a temp file and pass with -f; locally,
# generate_appcast reads the key from the Keychain automatically.
KEY_ARGS=()
TMP_KEY=""
if [[ -n "${SENANI_SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  TMP_KEY="$(mktemp)"
  printf '%s' "${SENANI_SPARKLE_ED_PRIVATE_KEY}" > "${TMP_KEY}"
  KEY_ARGS=(-f "${TMP_KEY}")
fi
cleanup() { [[ -n "${TMP_KEY}" ]] && rm -f "${TMP_KEY}"; }
trap cleanup EXIT

echo "Signing updates in ${RELEASE_DIR} and writing appcast (feed: ${FEED_URL})…"
"${GEN_APPCAST}" "${KEY_ARGS[@]}" \
  --download-url-prefix "$(dirname "${FEED_URL}")/" \
  "${RELEASE_DIR}"

# generate_appcast writes ${RELEASE_DIR}/appcast.xml with EdDSA sparkle:edSignature
# attributes on each <enclosure>. Confirm the signature attribute is present.
APPCAST="${RELEASE_DIR}/appcast.xml"
[[ -f "${APPCAST}" ]] || { echo "error: appcast.xml not produced"; exit 1; }
grep -q 'sparkle:edSignature=' "${APPCAST}" || { echo "error: appcast has no EdDSA signatures"; exit 1; }
echo "OK: signed appcast at ${APPCAST}"
```

- [ ] **6.3** Make it executable and lint:
```bash
chmod +x /Users/vishalkumar/Downloads/qmail/Scripts/sign_appcast.sh
bash -n /Users/vishalkumar/Downloads/qmail/Scripts/sign_appcast.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **6.4** **(Manual verification with a real build)** After a signed `.app` exists, dry-run the signer against a zipped build:
```bash
mkdir -p /tmp/senani-release
ditto -c -k --keepParent "build/Senani.app" "/tmp/senani-release/Senani-1.4.2.zip"
Scripts/sign_appcast.sh /tmp/senani-release "https://updates.example.invalid/appcast.xml"
```
Expected: `OK: signed appcast at /tmp/senani-release/appcast.xml`, and:
```bash
grep -o 'sparkle:edSignature="[^"]*"' /tmp/senani-release/appcast.xml | head -1
```
prints a non-empty `sparkle:edSignature="…"`.

- [ ] **6.5** Commit: `feat(release): sign_appcast.sh — EdDSA-signed appcast generation`.

---

### Task 7 — `Scripts/release.sh` (build → sign → notarize → appcast → publish)

Orchestrates the full release, delegating signing/notarization to the code-signing plan's scripts.

- [ ] **7.1** Create `Scripts/release.sh`:

```bash
#!/usr/bin/env bash
# Full Senani release: build the .app, sign + notarize (code-signing plan),
# sign the appcast (EdDSA), and publish the artifacts to the update feed host.
# Privacy: nothing here phones home; the only published artifacts are the
# signed .app .zip and the signed appcast.xml.
set -euo pipefail

VERSION="${1:?usage: release.sh <marketing-version> [build-number]}"
BUILD_NUMBER="${2:-$(date +%Y%m%d%H%M)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${REPO_ROOT}/dist/release"
FEED_URL="${SENANI_SU_FEED_URL:?set SENANI_SU_FEED_URL to the appcast URL}"

mkdir -p "${RELEASE_DIR}"

echo "==> 1/5 Build + bundle Senani.app (code-signing plan owns bundling)"
# bundle.sh wraps the SwiftPM executable into Senani.app, substituting the
# Info.plist template tokens (incl. ${SU_FEED_URL}, ${SU_PUBLIC_ED_KEY}).
SU_FEED_URL="${FEED_URL}" \
SU_PUBLIC_ED_KEY="${SENANI_SU_PUBLIC_ED_KEY:?set SENANI_SU_PUBLIC_ED_KEY}" \
MARKETING_VERSION="${VERSION}" BUILD_NUMBER="${BUILD_NUMBER}" \
  "${REPO_ROOT}/Scripts/bundle.sh" "${RELEASE_DIR}/Senani.app"

echo "==> 2/5 Code sign (Developer ID) — code-signing plan"
"${REPO_ROOT}/Scripts/codesign.sh" "${RELEASE_DIR}/Senani.app"

echo "==> 3/5 Notarize + staple — code-signing plan"
"${REPO_ROOT}/Scripts/notarize.sh" "${RELEASE_DIR}/Senani.app"

echo "==> 4/5 Zip the signed, stapled app and sign the appcast"
ditto -c -k --keepParent "${RELEASE_DIR}/Senani.app" "${RELEASE_DIR}/Senani-${VERSION}.zip"
"${REPO_ROOT}/Scripts/sign_appcast.sh" "${RELEASE_DIR}" "${FEED_URL}"

echo "==> 5/5 Publish to the feed host"
# Parameterized publish. Default: rsync to ${SENANI_UPDATES_RSYNC_TARGET}.
# Replace with your host's mechanism (S3 sync, gh-pages push, etc.).
if [[ -n "${SENANI_UPDATES_RSYNC_TARGET:-}" ]]; then
  rsync -avz --delete-after \
    "${RELEASE_DIR}/appcast.xml" "${RELEASE_DIR}/Senani-${VERSION}.zip" \
    "${SENANI_UPDATES_RSYNC_TARGET}/"
  echo "Published appcast + zip to ${SENANI_UPDATES_RSYNC_TARGET}"
else
  echo "SENANI_UPDATES_RSYNC_TARGET unset — artifacts left in ${RELEASE_DIR} for manual upload."
fi

echo "Release ${VERSION} (build ${BUILD_NUMBER}) complete."
```

> `Scripts/bundle.sh`, `Scripts/codesign.sh`, `Scripts/notarize.sh` are owned by the **code-signing plan**. `release.sh` calls them by their documented contract: `bundle.sh <out.app>` (consumes `SU_FEED_URL`/`SU_PUBLIC_ED_KEY`/version env), `codesign.sh <app>`, `notarize.sh <app>`. If their flags differ when that plan lands, update the call sites here and record the deviation.

- [ ] **7.2** Lint:
```bash
chmod +x /Users/vishalkumar/Downloads/qmail/Scripts/release.sh
bash -n /Users/vishalkumar/Downloads/qmail/Scripts/release.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **7.3** Commit: `feat(release): release.sh — build→sign→notarize→appcast→publish`.

---

### Task 8 — CI release job

Extend the existing `.github/workflows/release.yml` (currently a placeholder) to run the release on a `v*` tag, injecting the EdDSA private key + feed URL from secrets.

- [ ] **8.1** Replace the body of `.github/workflows/release.yml`:

```yaml
name: Release

# Builds, signs, notarizes, and publishes a signed Sparkle update on a version tag.
on:
  push:
    tags:
      - "v*"
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-14
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app

      - name: Install Sparkle tools
        run: brew install --cask sparkle

      - name: Derive version from tag
        id: ver
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Build, sign, notarize, sign appcast, publish
        env:
          # --- code-signing plan secrets (Developer ID + notarytool) ---
          SENANI_SIGNING_CERTIFICATE_P12: ${{ secrets.SENANI_SIGNING_CERTIFICATE_P12 }}
          SENANI_SIGNING_CERTIFICATE_PASSWORD: ${{ secrets.SENANI_SIGNING_CERTIFICATE_PASSWORD }}
          SENANI_NOTARY_PROFILE: ${{ secrets.SENANI_NOTARY_PROFILE }}
          # --- auto-update (this plan) ---
          SENANI_SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SENANI_SPARKLE_ED_PRIVATE_KEY }}
          SENANI_SU_PUBLIC_ED_KEY: ${{ vars.SENANI_SU_PUBLIC_ED_KEY }}
          SENANI_SU_FEED_URL: ${{ vars.SENANI_SU_FEED_URL }}
          SENANI_UPDATES_RSYNC_TARGET: ${{ secrets.SENANI_UPDATES_RSYNC_TARGET }}
        run: ./Scripts/release.sh "${{ steps.ver.outputs.version }}" "${GITHUB_RUN_NUMBER}"

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
          prerelease: ${{ contains(github.ref_name, '-') }}
          files: dist/release/Senani-*.zip
```

> Secrets vs. variables: `SENANI_SU_PUBLIC_ED_KEY` and `SENANI_SU_FEED_URL` are **public** → repo *variables*. `SENANI_SPARKLE_ED_PRIVATE_KEY`, the signing cert, and the deploy target are **secret**. The EdDSA private key is never written to disk except the transient temp file in `sign_appcast.sh` (trap-cleaned).

- [ ] **8.2** Validate workflow YAML:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('/Users/vishalkumar/Downloads/qmail/.github/workflows/release.yml')); print('YAML OK')"
```
Expected: `YAML OK`.

- [ ] **8.3** Commit: `ci(release): wire signed Sparkle release on v* tags`.

---

### Task 9 — Manual verification of the Sparkle integration

Sparkle's runtime behavior can't be unit-tested headlessly; verify it on a real signed build with these documented steps.

- [ ] **9.1** Confirm the shipped Info.plist has profiling OFF and the right keys (after `bundle.sh`):
```bash
/usr/libexec/PlistBuddy -c "Print :SUEnableSystemProfiling" dist/release/Senani.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" dist/release/Senani.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" dist/release/Senani.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" dist/release/Senani.app/Contents/Info.plist
```
Expected: `false`, `false`, the real feed URL, the real base64 public key (not the placeholders).

- [ ] **9.2** Confirm Sparkle.framework is embedded and signed inside the app:
```bash
codesign --verify --deep --strict --verbose=2 dist/release/Senani.app 2>&1 | tail -3
ls dist/release/Senani.app/Contents/Frameworks/ | grep -i sparkle
```
Expected: `valid on disk` / `satisfies its Designated Requirement`, and `Sparkle.framework` listed.

- [ ] **9.3** Confirm no profiling parameters leave the app. Point the feed at a local server, run the app, choose **Check for Updates…**, and inspect the request:
```bash
# In one terminal, log requests to a local feed:
cd /tmp/senani-release && python3 -m http.server 8099 --bind 127.0.0.1
# Launch a build whose SUFeedURL = http://127.0.0.1:8099/appcast.xml, then
# menu → Check for Updates…  Observe the server log line for the GET.
```
Expected: the access log shows a bare `GET /appcast.xml` with **no** query parameters (no `?cpu=…&osVersion=…` profile string). If any profile params appear, profiling is leaking — fail and revisit Task 4.2 / 5.1.

- [ ] **9.4** End-to-end update test: install version `1.4.1`, publish a signed `1.4.2` appcast, choose **Check for Updates…**.
  Expected: Sparkle shows "A new version (1.4.2) is available", downloads, verifies the EdDSA signature + Apple code signature, and offers to relaunch. A version-equal feed shows "You're up to date." A malformed appcast shows Sparkle's "update could not be checked" error and leaves the app untouched — matching the pure `UpdateDecision.unreadableFeed` path.

- [ ] **9.5** Record the observed outputs in the PR description as the integration evidence (per superpowers:verification-before-completion — evidence before assertions).

---

## Self-Review

**Scope coverage vs. the brief:**
- [x] **Sparkle 2 recommended + justified vs. hand-rolled** — see "Why Sparkle 2" (security-critical verify/replace, EdDSA, code-signature continuity, privacy-to-zero).
- [x] **Integrated into `SenaniApp/` build** — Task 1 adds the SwiftPM dependency; the `.app` bundling dependency on the code-signing plan is flagged in Architecture + the dependency callout.
- [x] **Signed appcast** — `generate_keys` (Task 6.1) + `generate_appcast` via `Scripts/sign_appcast.sh` (Task 6.2) producing EdDSA `sparkle:edSignature`; hosted at the human feed URL; `SUFeedURL` points at it (Task 5). Delivers the signed+notarized `.app` (Task 7 zips the stapled app).
- [x] **Privacy** — profiling/metrics OFF in plist (`SUEnableSystemProfiling = NO`) AND in code (`UpdaterPrivacyDelegate` + `sendsSystemProfile = false`); automatic checks opt-in (`SUEnableAutomaticChecks = NO`); exact keys documented (Task 5.1 note). Verified by the no-query-params manual check (9.3).
- [x] **In-app "Check for Updates" menu + view model** — `CheckForUpdatesCommand` (Task 4.4) + the pure `UpdateDecision`/`SemanticVersion` (Tasks 2–3).
- [x] **`Scripts/release.sh`** — build → sign (code-signing plan) → notarize → appcast sign → publish (Task 7); CI job (Task 8).
- [x] **Tests for version-compare/decision glue (pure)** — newer→offer, same/older→none, malformed→none, nil item→none (Tasks 2–3). Sparkle integration verified by documented manual steps + expected output (Task 9).

**Format:** required header + REQUIRED SUB-SKILL line; Goal / Architecture / Tech Stack / File Structure present; infra tasks use exact commands + expected output; testable Swift glue uses TDD (failing test → run → implement → pass). Complete code/config/scripts, no placeholders except explicitly-flagged human-input tokens (`${SU_FEED_URL}`, `${SU_PUBLIC_ED_KEY}`, key placeholders) which are documented as inputs and never the shipped values. Secrets (EdDSA private key, feed write creds) flagged as inputs and never committed.

**Risks / open items:**
- The **code-signing plan** (`2026-05-31-code-signing-and-notarization.md`) does not exist in the repo yet. Tasks 5/7/9 assume its `bundle.sh`/`codesign.sh`/`notarize.sh` contract; when it lands, reconcile flag names. Tasks 1–4 (Sparkle integration + pure logic + menu) are independent and can ship first.
- **Sparkle 2 delegate API** for profile suppression (`feedParameters(for:sendingSystemProfile:)`) is pinned to 2.6.x; if a linked version renames it, keep the contract (return `[]`) and record the deviation in Task 4.2.
- The published artifact format is `.zip` (Sparkle's recommended format for in-place updates, preserves the notarization staple). A `.dmg` for first-download distribution is the code-signing plan's concern, not the update channel.
```