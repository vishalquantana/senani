# One-Time License Keys — Offline Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new app-tier Swift package `SenaniLicensing` that verifies one-time license keys **fully offline** with no network, no accounts, no server, and no telemetry — exactly as ARCHITECTURE.md's trust model demands. The package embeds only an **Ed25519 PUBLIC key** and exposes `LicenseVerifier(publicKey:).verify(_ key: String) -> LicenseStatus`, returning `.valid(tier)` / `.invalid` / `.tampered` / `.malformed`. Tier (`core` / `pro`) gates a `Feature` enum so the $99 Core tier unlocks the Phase-2 Core agents and the $199 Pro tier additionally unlocks the Phase-3 Pro sales-suite agents. A separate **offline seller-side** `Scripts/sign_license.swift` generates the keypair and signs keys; the PRIVATE key NEVER lives in the app or repo. The activated key is persisted in the macOS Keychain. The crypto verification logic is pure and deterministic — every status is unit-tested with an **in-test** keypair (no real key committed).

**Architecture:** A standalone SwiftPM **library** package `Packages/SenaniLicensing` depending only on Apple's `CryptoKit` (system framework) and `Foundation` — no engine packages, no MLX, no Gmail, no SwiftUI in the core. A license key is a compact base32-grouped string `XXXXX-XXXXX-…` whose decoded bytes are `payloadBytes ‖ signature(64 bytes)`. `payloadBytes` is the canonical **deterministic JSON** encoding of a `LicensePayload` (license id, tier, issue date, optional buyer email + seat). `LicenseVerifier` decodes the grouped base32 (→ `.malformed` on any decode failure), splits payload/signature, decodes the payload JSON (→ `.malformed`), then calls `Curve25519.Signing.PublicKey.isValidSignature(_:for:)` over the **exact canonical payload bytes**: a good signature from the matching key → `.valid(payload.tier)`; a structurally valid key whose payload bytes were altered after signing → signature check fails → `.tampered`; a key signed by a *different* private key → signature check fails → `.invalid`. (`.tampered` vs `.invalid` is distinguished by a one-byte algorithm/version tag the signer embeds and the verifier re-derives — see Task 6.) Tier → feature gating is a pure `Feature.minimumTier` table. The app wires it via a `LicenseState` adapter that reads/writes the Keychain and exposes an `unlocks(_:) -> Bool` the composition root consults; the actual SwiftUI is limited to an **activation-screen stub** (input field + Activate button + status), with the deeper UI deferred.

**Tech Stack:** Swift 6.2 (strict concurrency, `swift-tools-version: 6.0`), Swift Package Manager (library product), Swift Testing (`import Testing`, ships with the toolchain), Apple `CryptoKit` (`Curve25519.Signing`). Target platform macOS 14, Apple Silicon. No third-party dependencies. No network, no server, no phone-home anywhere in this plan.

**Working directory:** All `swift` commands run from `Packages/SenaniLicensing/` unless stated otherwise. The signer script and its smoke test run from the repo root. The app-wiring task (Task 11) runs from `SenaniApp/`.

**Source docs:** Implements ROADMAP.md "Deferred — Packaging & licensing → One-time license keys (offline verification)" and the $99 Core / $199 Pro tiers. Honors ARCHITECTURE.md "No telemetry, no accounts … everything on-device" and the trust spine. Aligns with `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` §3 (`AppEnvironment` composition root), §4 (conventions: composition root only, macOS 14 / Swift 6.2 / Swift Testing, TDD + bite-sized steps + frequent commits), and §5 ("license-key keypair … supplied by the human").

**Out of scope (separate / deferred plans):** Code signing + notarization; Auto-update; the purchase/checkout flow and key delivery (email/Gumroad/Stripe — a seller concern, not in the app); a license *server* or any online activation (explicitly forbidden by the trust model); the full Settings → License management UI beyond the activation-screen stub; per-feature paywall copy/upsell design. This plan ships the verifier, the tier→feature gate, the Keychain store, the offline signer script, and the wiring seam + activation stub only.

---

## Cross-package assumptions (state these to the human before coding)

The `SenaniLicensing` **core** depends on nothing but `CryptoKit` + `Foundation`, so it compiles in isolation with zero engine-package coupling. The only cross-tier touch points are the app-wiring task (Task 11) and the tier-name alignment:

- **`Autonomy`/`Tier` naming:** ROADMAP tiers are **Core ($99)** and **Pro ($199)**. This package defines its own `LicenseTier { case core, pro }` (raw `String` `"core"`/`"pro"`); it does NOT depend on `SenaniRules.Autonomy` (different concept). No frozen package defines a tier type — this is greenfield.
- **Agent ids (verified from the agent plans):** Core-tier agents are `triage`, `reply-drafter`, `booking`, `daily-digest`, `inbox-hygiene` (Roadmap Phases 1–2). Pro-tier agents are `lead-qualifier`, `proposal-tracker`, `follow-up`, `outreach`, `invoice-finance` (Roadmap Phase 3). `Feature` cases use these exact stable ids so the gate maps 1:1 to `Agent.id`. (`outreach` / `invoice-finance` agent plans are not yet written; their ids are pinned here so the gate is complete and the future plans adopt them.)
- **`AppEnvironment` (app-shell plan, reconciliation §3):** `@MainActor public final class AppEnvironment: ObservableObject` constructs the live graph and builds the `Orchestrator` with `AgentRegistry(agents:)`. Today (Phase 0) it bootstraps with `AgentRegistry(agents: [])` and a `NoopAgent` triage. Task 11 adds a `licenseState: LicenseState` property and **filters the agent list by tier before constructing `AgentRegistry`** — the single gating seam. If the app-shell plan has not yet migrated `AppState` → `AppEnvironment` in the worker's worktree, Task 11 records the dependency and wires the same `licenseState` property onto whatever injection type shipped (do NOT introduce a third type). The Task-11 code is illustrative; the worker adapts it to the real `AppEnvironment` it finds, per §3's "code to the pinned contract; adapt if the built API differs."
- **macOS Keychain:** Task 9 uses the **Security framework** `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` directly with a generic-password item (service `in.quantana.senani.license`, account `activated-key`). It does NOT depend on `SenaniGmail.KeychainTokenStore` (that stores OAuth tokens, a different item and shape) — but it mirrors its conventions. Keychain access is the only OS side effect in the package; all crypto is pure.

---

## File Structure

```
Packages/SenaniLicensing/
  Package.swift
  Sources/SenaniLicensing/
    LicenseTier.swift          # LicenseTier enum (core/pro), Comparable so .pro >= .core
    LicensePayload.swift       # the signed struct + CANONICAL deterministic JSON encode/decode (the exact bytes that get signed)
    Base32Grouped.swift        # Crockford base32 encode/decode + XXXXX-XXXXX grouping/ungrouping (pure, no Foundation crypto)
    LicenseStatus.swift        # LicenseStatus enum (.valid(tier)/.invalid/.tampered/.malformed) + Equatable
    LicenseVerifier.swift      # LicenseVerifier(publicKey:) ; verify(_ key: String) -> LicenseStatus (pure, offline)
    Feature.swift              # Feature enum (per-agent + suites) + minimumTier table + LicenseTier.unlocks(_:)
    LicenseKeychainStore.swift # save/load/clear the activated key string in the macOS Keychain (Security framework)
    EmbeddedPublicKey.swift    # the app's embedded Ed25519 PUBLIC key (base64), + LicenseVerifier.senani() factory
  Tests/SenaniLicensingTests/
    Base32GroupedTests.swift
    LicensePayloadCodecTests.swift
    LicenseVerifierTests.swift     # valid/tampered/invalid/malformed, all driven by an IN-TEST keypair
    FeatureGateTests.swift         # core does NOT unlock pro; pro unlocks all
    LicenseKeychainStoreTests.swift
    TestSupport.swift              # in-test keypair generation + a SignerHelper that mirrors the script's signing
Scripts/
  sign_license.swift          # OFFLINE seller-side: `gen-key` (new keypair) + `sign` (emit a license key). Private key never in repo.
  README-licensing.md         # key-custody doc: where the private key lives, rotation, how to embed the public key
SenaniApp/Sources/SenaniApp/
  License/LicenseState.swift           # @MainActor ObservableObject adapter: Keychain ↔ verifier ↔ unlocks(_:)
  License/ActivationView.swift         # the activation-screen STUB (input + Activate + status); deeper UI deferred
  AppEnvironment.swift                 # MODIFY: add licenseState + filter agents by tier before AgentRegistry
```

Each file has one responsibility. The verifier depends only on `CryptoKit` + the pure codecs; the Keychain store is the only file touching the OS; the app files are the only ones importing SwiftUI / `AppEnvironment`.

---

### Task 1: Package scaffold + CryptoKit dependency

**Files:**
- Create: `Packages/SenaniLicensing/Package.swift`
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseTier.swift` (temporary one-line marker so the target compiles)
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/Base32GroupedTests.swift` (placeholder import-only test)

- [ ] **Step 1: Write a failing import test**

Create `Packages/SenaniLicensing/Tests/SenaniLicensingTests/Base32GroupedTests.swift`:

```swift
import Testing
import CryptoKit
@testable import SenaniLicensing

@Test func packageImportsCompileAndCryptoKitLinks() {
    // Proves the package builds and CryptoKit (Ed25519) links.
    let key = Curve25519.Signing.PrivateKey()
    #expect(key.publicKey.rawRepresentation.count == 32)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test
```

Expected: failure — no `Package.swift` / no `SenaniLicensing` target (`error: no such module 'SenaniLicensing'` / manifest not found).

- [ ] **Step 3: Create the manifest (no external deps; CryptoKit is a system framework)**

Create `Packages/SenaniLicensing/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniLicensing",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniLicensing", targets: ["SenaniLicensing"]),
    ],
    targets: [
        .target(name: "SenaniLicensing"),
        .testTarget(name: "SenaniLicensingTests", dependencies: ["SenaniLicensing"]),
    ]
)
```

> `CryptoKit` and `Security` are linked automatically as system frameworks when `import`ed on macOS 14 — no `linkerSettings` needed under SwiftPM.

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseTier.swift` with a single line so the target is non-empty:

```swift
// SenaniLicensing — offline one-time license keys. Types defined in Task 2+.
import Foundation
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: package scaffold linking CryptoKit"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: `LicenseTier` (core/pro, Comparable)

**Files:**
- Edit: `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseTier.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/FeatureGateTests.swift` (new)

- [ ] **Step 1: Write a failing test**

Create `Packages/SenaniLicensing/Tests/SenaniLicensingTests/FeatureGateTests.swift`:

```swift
import Testing
@testable import SenaniLicensing

@Test func tierRawValuesAreStableWireStrings() {
    #expect(LicenseTier.core.rawValue == "core")
    #expect(LicenseTier.pro.rawValue == "pro")
    #expect(LicenseTier(rawValue: "pro") == .pro)
    #expect(LicenseTier(rawValue: "enterprise") == nil)
}

@Test func proOutranksCore() {
    #expect(LicenseTier.pro > LicenseTier.core)
    #expect(LicenseTier.core < LicenseTier.pro)
    #expect(LicenseTier.pro >= LicenseTier.pro)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter FeatureGateTests
```

Expected: failure — `LicenseTier` undefined.

- [ ] **Step 3: Implement `LicenseTier`**

Replace `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseTier.swift`:

```swift
import Foundation

/// The two purchasable tiers. Raw value is the stable wire string embedded in a
/// signed license payload. Ordered so `.pro > .core`: a Pro key satisfies any
/// requirement a Core key does (Pro is a superset).
public enum LicenseTier: String, Sendable, Codable, CaseIterable, Comparable {
    case core   // $99 — Phase-1/2 agents
    case pro    // $199 — Phase-1/2 + Phase-3 sales suite

    private var rank: Int {
        switch self {
        case .core: return 0
        case .pro:  return 1
        }
    }

    public static func < (lhs: LicenseTier, rhs: LicenseTier) -> Bool {
        lhs.rank < rhs.rank
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter FeatureGateTests
```

Expected: both tests pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: LicenseTier (core/pro, Comparable, stable raw strings)"
```

(Append the standard trailer.)

---

### Task 3: `LicensePayload` + canonical deterministic JSON

The signed bytes MUST be byte-stable: the same payload must encode to the same bytes on the signer and the verifier, or signatures never match. We avoid `JSONEncoder`'s non-deterministic key order by hand-building canonical JSON with sorted keys.

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/LicensePayload.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicensePayloadCodecTests.swift` (new)

- [ ] **Step 1: Write failing tests**

Create `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicensePayloadCodecTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniLicensing

@Test func canonicalBytesAreDeterministicAndRoundTrip() throws {
    let payload = LicensePayload(
        licenseID: "LIC-0001",
        tier: .pro,
        issued: Date(timeIntervalSince1970: 1_700_000_000),
        buyerEmail: "ramesh@quantana.in",
        seats: 1
    )
    let a = try payload.canonicalBytes()
    let b = try payload.canonicalBytes()
    #expect(a == b)                                  // deterministic: same input → same bytes
    let decoded = try LicensePayload(canonicalBytes: a)
    #expect(decoded == payload)                      // round-trips exactly
}

@Test func canonicalJSONHasSortedKeysAndIntegerSeconds() throws {
    let payload = LicensePayload(
        licenseID: "Z", tier: .core,
        issued: Date(timeIntervalSince1970: 1_700_000_000),
        buyerEmail: nil, seats: nil
    )
    let json = String(decoding: try payload.canonicalBytes(), as: UTF8.self)
    // keys appear in sorted order; optionals omitted when nil; issued is integer epoch seconds
    #expect(json == #"{"issued":1700000000,"licenseID":"Z","tier":"core"}"#)
}

@Test func malformedBytesThrow() {
    #expect(throws: (any Error).self) {
        _ = try LicensePayload(canonicalBytes: Data("not json".utf8))
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter LicensePayloadCodecTests
```

Expected: failure — `LicensePayload` undefined.

- [ ] **Step 3: Implement `LicensePayload`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/LicensePayload.swift`:

```swift
import Foundation

/// The data the seller signs. Compact and stable: licenseID, tier, issue date,
/// and optional buyer email + seat count. The SIGNED bytes are this struct's
/// CANONICAL JSON (sorted keys, nils omitted, date as integer epoch seconds) so
/// the signer and verifier agree on the exact bytes — JSONEncoder's key order is
/// not guaranteed, so we build the JSON by hand.
public struct LicensePayload: Sendable, Equatable {
    public let licenseID: String
    public let tier: LicenseTier
    public let issued: Date
    public let buyerEmail: String?
    public let seats: Int?

    public init(licenseID: String, tier: LicenseTier, issued: Date,
                buyerEmail: String? = nil, seats: Int? = nil) {
        self.licenseID = licenseID
        self.tier = tier
        self.issued = issued
        self.buyerEmail = buyerEmail
        self.seats = seats
    }

    enum CodingError: Error { case malformed }

    /// Canonical signed bytes: a hand-built JSON object with keys in sorted order,
    /// optionals omitted when nil, `issued` as integer epoch seconds. Deterministic.
    public func canonicalBytes() throws -> Data {
        // String fields are JSON-escaped; our inputs are simple, but escape anyway
        // so an email/id with a quote can't break the bytes (or signature) silently.
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:   out.unicodeScalars.append(ch)
                }
            }
            return out
        }
        // Build (key, jsonValue) pairs, then sort by key for determinism.
        var fields: [(String, String)] = [
            ("issued", String(Int(issued.timeIntervalSince1970.rounded()))),
            ("licenseID", "\"\(esc(licenseID))\""),
            ("tier", "\"\(esc(tier.rawValue))\""),
        ]
        if let buyerEmail { fields.append(("buyerEmail", "\"\(esc(buyerEmail))\"")) }
        if let seats { fields.append(("seats", String(seats))) }
        fields.sort { $0.0 < $1.0 }
        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    /// Parse canonical (or any equivalent) JSON bytes back into a payload.
    public init(canonicalBytes data: Data) throws {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let licenseID = obj["licenseID"] as? String,
            let tierRaw = obj["tier"] as? String,
            let tier = LicenseTier(rawValue: tierRaw),
            let issuedSeconds = obj["issued"] as? NSNumber
        else { throw CodingError.malformed }
        self.licenseID = licenseID
        self.tier = tier
        self.issued = Date(timeIntervalSince1970: issuedSeconds.doubleValue)
        self.buyerEmail = obj["buyerEmail"] as? String
        if let seats = obj["seats"] as? NSNumber { self.seats = seats.intValue } else { self.seats = nil }
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter LicensePayloadCodecTests
```

Expected: all three tests pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: LicensePayload with deterministic canonical-JSON signed bytes"
```

(Append the standard trailer.)

---

### Task 4: Crockford base32 + `XXXXX-XXXXX` grouping

The wire format is human-typable: uppercase Crockford base32 (no `I`/`L`/`O`/`U`, case-insensitive on input) grouped in 5-char blocks separated by `-`. Decode must reject anything that is not a clean key (→ feeds `.malformed`).

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/Base32Grouped.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/Base32GroupedTests.swift` (replace placeholder)

- [ ] **Step 1: Replace the placeholder with real failing tests**

Replace `Packages/SenaniLicensing/Tests/SenaniLicensingTests/Base32GroupedTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniLicensing

@Test func encodeDecodeRoundTrips() throws {
    let bytes = Data((0..<37).map { UInt8($0) })   // arbitrary, not a multiple of 5
    let grouped = Base32Grouped.encode(bytes)
    #expect(grouped.contains("-"))                 // grouped into XXXXX-XXXXX blocks
    let decoded = try Base32Grouped.decode(grouped)
    #expect(decoded == bytes)
}

@Test func decodeIsCaseInsensitiveAndIgnoresDashes() throws {
    let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let grouped = Base32Grouped.encode(bytes)
    let lowerNoDash = grouped.lowercased().replacingOccurrences(of: "-", with: "")
    #expect(try Base32Grouped.decode(lowerNoDash) == bytes)
}

@Test func decodeRejectsIllegalCharacters() {
    #expect(throws: (any Error).self) {
        // 'U' is excluded from the Crockford alphabet
        _ = try Base32Grouped.decode("UUUUU-UUUUU")
    }
    #expect(throws: (any Error).self) {
        _ = try Base32Grouped.decode("!!!!!")
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter Base32GroupedTests
```

Expected: failure — `Base32Grouped` undefined.

- [ ] **Step 3: Implement `Base32Grouped`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/Base32Grouped.swift`:

```swift
import Foundation

/// Crockford base32 (alphabet excludes I, L, O, U) with `XXXXX-XXXXX` grouping.
/// Encoding is uppercase/grouped; decoding is case-insensitive and ignores dashes
/// and surrounding whitespace. Pure — no crypto, no Foundation Data(base64:).
public enum Base32Grouped {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")  // 32 symbols, Crockford
    static let groupSize = 5

    enum DecodeError: Error { case illegalCharacter, truncated }

    public static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var symbols = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                symbols.append(alphabet[(value >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            symbols.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        // Group into 5-char blocks separated by '-'.
        var grouped = ""
        for (i, ch) in symbols.enumerated() {
            if i > 0 && i % groupSize == 0 { grouped.append("-") }
            grouped.append(ch)
        }
        return grouped
    }

    public static func decode(_ string: String) throws -> Data {
        // Build reverse lookup once; treat lowercase as uppercase.
        let cleaned = string.uppercased()
            .filter { $0 != "-" && !$0.isWhitespace }
        var lookup: [Character: Int] = [:]
        for (i, ch) in alphabet.enumerated() { lookup[ch] = i }

        var bits = 0
        var value = 0
        var out = Data()
        for ch in cleaned {
            guard let v = lookup[ch] else { throw DecodeError.illegalCharacter }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter Base32GroupedTests
```

Expected: all three tests pass (including the original CryptoKit-link test if still present — keep it or fold it into Step 1; either is fine as long as the suite is green).

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: Crockford base32 + XXXXX-XXXXX grouped codec"
```

(Append the standard trailer.)

---

### Task 5: `LicenseStatus` enum

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseStatus.swift`
- Test: covered indirectly by Task 6; add a tiny standalone test here.

- [ ] **Step 1: Write a failing test**

Append to `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseVerifierTests.swift` (create the file):

```swift
import Testing
@testable import SenaniLicensing

@Test func statusEquatableDistinguishesTiers() {
    #expect(LicenseStatus.valid(.core) == .valid(.core))
    #expect(LicenseStatus.valid(.core) != .valid(.pro))
    #expect(LicenseStatus.invalid != .tampered)
    #expect(LicenseStatus.malformed != .invalid)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests
```

Expected: failure — `LicenseStatus` undefined.

- [ ] **Step 3: Implement `LicenseStatus`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseStatus.swift`:

```swift
import Foundation

/// The result of verifying a license key, fully offline.
/// - `.valid(tier)`  : signature checks out against the embedded public key.
/// - `.invalid`      : structurally a key, but signed by a DIFFERENT private key.
/// - `.tampered`     : structurally a key, payload bytes were altered after signing.
/// - `.malformed`    : not decodable as a key at all (bad base32, wrong length, bad JSON).
public enum LicenseStatus: Sendable, Equatable {
    case valid(LicenseTier)
    case invalid
    case tampered
    case malformed

    /// The tier if and only if the key is valid; nil otherwise. Convenience for gating.
    public var tier: LicenseTier? {
        if case .valid(let t) = self { return t }
        return nil
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests
```

Expected: the status test passes.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: LicenseStatus (valid/invalid/tampered/malformed)"
```

(Append the standard trailer.)

---

### Task 6: `LicenseVerifier` — the offline Ed25519 verification (the heart)

This is the crypto verification logic — pure, deterministic, fully unit-testable. The key bytes are `tag(1) ‖ payloadBytes ‖ signature(64)`. The `tag` byte is `0x01` (algorithm = Ed25519 / format v1); the signature signs `tag ‖ payloadBytes`. The verifier re-derives the expected `tag` to split `.malformed` (unknown/short structure) from `.tampered`/`.invalid` (structure OK, signature fails). `.tampered` vs `.invalid` cannot be told apart by Ed25519 alone (a failed verify is a failed verify), so we make a deliberate, documented choice: **if the decoded payload JSON parses cleanly AND has the well-formed shape, a failed signature is reported as `.tampered`; if the payload JSON does not parse but the byte structure is otherwise key-shaped, it is `.malformed`; a failed signature over a well-formed-but-foreign payload is `.invalid` ONLY when the payload carries a `licenseID` matching the embedded-issuer prefix we expect, else `.tampered`.** To make this testable and unambiguous, the signer stamps the payload with our issuer; see the precise rule in the implementation comment and the tests below, which pin the exact mapping.

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseVerifier.swift`
- Create: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/TestSupport.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseVerifierTests.swift` (append)

- [ ] **Step 1: Add the in-test signer helper**

Create `Packages/SenaniLicensing/Tests/SenaniLicensingTests/TestSupport.swift`:

```swift
import Foundation
import CryptoKit
@testable import SenaniLicensing

/// Mirrors what the offline Scripts/sign_license.swift does, but with an IN-TEST
/// keypair so no real private key is ever committed. Produces a grouped license key.
enum SignerHelper {
    static let formatTag: UInt8 = 0x01   // Ed25519 / v1 — MUST match LicenseVerifier.formatTag

    /// Sign a payload with `privateKey`, return the grouped XXXXX-XXXXX key string.
    static func makeKey(_ payload: LicensePayload,
                        signedBy privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payloadBytes = try payload.canonicalBytes()
        var signed = Data([formatTag])
        signed.append(payloadBytes)
        let signature = try privateKey.signature(for: signed)   // signs tag ‖ payload
        var keyBytes = signed
        keyBytes.append(signature)                              // tag ‖ payload ‖ sig(64)
        return Base32Grouped.encode(keyBytes)
    }
}
```

- [ ] **Step 2: Write the failing verification tests**

Append to `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseVerifierTests.swift`:

```swift
import Foundation
import CryptoKit

private func corePayload() -> LicensePayload {
    LicensePayload(licenseID: "LIC-CORE", tier: .core,
                   issued: Date(timeIntervalSince1970: 1_700_000_000))
}
private func proPayload() -> LicensePayload {
    LicensePayload(licenseID: "LIC-PRO", tier: .pro,
                   issued: Date(timeIntervalSince1970: 1_700_000_000),
                   buyerEmail: "buyer@example.com", seats: 1)
}

@Test func validKeyVerifiesWithCorrectTier() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey)

    let coreKey = try SignerHelper.makeKey(corePayload(), signedBy: priv)
    #expect(verifier.verify(coreKey) == .valid(.core))

    let proKey = try SignerHelper.makeKey(proPayload(), signedBy: priv)
    #expect(verifier.verify(proKey) == .valid(.pro))
}

@Test func wrongKeySignatureIsInvalid() throws {
    let sellerKey = Curve25519.Signing.PrivateKey()
    let attackerKey = Curve25519.Signing.PrivateKey()   // a DIFFERENT private key
    let verifier = LicenseVerifier(publicKey: sellerKey.publicKey)

    let forged = try SignerHelper.makeKey(proPayload(), signedBy: attackerKey)
    #expect(verifier.verify(forged) == .invalid)
}

@Test func tamperedPayloadIsTampered() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey)

    // Sign a CORE key, then flip the tier bytes in the payload while keeping the
    // original signature → structure is intact, signature no longer matches.
    let coreKey = try SignerHelper.makeKey(corePayload(), signedBy: priv)
    var bytes = try Base32Grouped.decode(coreKey)
    // Locate "core" in the payload region and overwrite with "pro\0"-ish bytes to
    // corrupt the signed content without changing total length.
    if let range = bytes.range(of: Data("core".utf8)) {
        bytes.replaceSubrange(range, with: Data("cor3".utf8))   // same length, altered
    }
    let tamperedKey = Base32Grouped.encode(bytes)
    #expect(verifier.verify(tamperedKey) == .tampered)
}

@Test func garbageStringIsMalformed() throws {
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey)

    #expect(verifier.verify("not-a-key") == .malformed)        // illegal base32 chars
    #expect(verifier.verify("") == .malformed)                 // empty
    #expect(verifier.verify("AAAAA-AAAAA") == .malformed)      // decodes but far too short
}
```

> **Tampered-vs-invalid pin:** the tamper test corrupts the **payload region** of a key whose signature was made by the SAME private key the verifier trusts → reported `.tampered`. The invalid test uses a payload signed by a DIFFERENT private key → reported `.invalid`. The implementation distinguishes them by attempting to verify the *embedded* signature against the *embedded* public key over the bytes as-presented (fails for both), then deciding: if the decoded payload's `tier` parses AND the byte layout is exactly `tag ‖ payload ‖ 64`, it is a real-but-rejected key — `.tampered` when the structure was internally consistent at decode and `.invalid` when the signature is a valid Ed25519 signature shape but over foreign content. See the implementation comment for the exact, deterministic rule the tests above lock in.

- [ ] **Step 3: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests
```

Expected: failure — `LicenseVerifier` undefined.

- [ ] **Step 4: Implement `LicenseVerifier`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseVerifier.swift`:

```swift
import Foundation
import CryptoKit

/// Verifies one-time license keys FULLY OFFLINE. Holds ONLY the Ed25519 public
/// key — the private key lives solely on the seller's offline machine. No network,
/// no accounts, no telemetry.
///
/// Key byte layout (before base32 grouping):
///   [0]        formatTag (0x01 = Ed25519 / v1)
///   [1 ..< n]  canonical payload JSON bytes
///   [n ..< n+64] Ed25519 signature over bytes[0 ..< n] (i.e. tag ‖ payload)
public struct LicenseVerifier: Sendable {
    static let formatTag: UInt8 = 0x01
    static let signatureLength = 64

    private let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    public func verify(_ key: String) -> LicenseStatus {
        // 1. Decode grouped base32. Any failure → not a key at all.
        guard let raw = try? Base32Grouped.decode(key) else { return .malformed }

        // 2. Structural minimum: tag(1) + at least 1 payload byte + signature(64).
        guard raw.count > 1 + Self.signatureLength, raw.first == Self.formatTag else {
            return .malformed
        }

        // 3. Split: signed region (tag ‖ payload) and the trailing 64-byte signature.
        let signedRegion = raw.prefix(raw.count - Self.signatureLength)   // tag ‖ payload
        let signature = raw.suffix(Self.signatureLength)
        let payloadBytes = signedRegion.dropFirst()                       // strip tag

        // 4. The payload JSON must parse, else the bytes aren't a real key → malformed.
        guard let payload = try? LicensePayload(canonicalBytes: Data(payloadBytes)) else {
            return .malformed
        }

        // 5. Verify the Ed25519 signature over the EXACT signed region with the
        //    embedded public key. A correct signature from the trusted key → valid.
        if publicKey.isValidSignature(Data(signature), for: Data(signedRegion)) {
            return .valid(payload.tier)
        }

        // 6. Signature failed but the key is structurally a real, parseable license.
        //    Re-derive the canonical bytes the payload SHOULD have produced: if they
        //    differ from the presented payload bytes, the payload was altered after
        //    signing → tampered. If they MATCH (payload intact, but the signature
        //    simply doesn't verify against our key), it was signed by another key
        //    → invalid (a forgery with a foreign key).
        let recanonical = (try? payload.canonicalBytes()) ?? Data()
        return recanonical == Data(payloadBytes) ? .invalid : .tampered
    }
}
```

> **Why step 6 is deterministic and matches the tests:** the *tamper* test rewrites `"core"`→`"cor3"` inside the signed bytes. `LicensePayload.init(canonicalBytes:)` still parses it (JSON valid), but re-canonicalizing the parsed payload reorders/normalizes nothing for these fields, so the re-derived bytes EQUAL the presented bytes only when the bytes are already canonical. Because the tamper altered a *value* that round-trips literally, we instead detect tamper via the mismatch path; to keep the two tests unambiguous, the tamper test corrupts a region such that re-canonicalization differs from the presented bytes. **If, while implementing, the worker finds a payload edit that round-trips identically (so step 6 mis-classifies), switch the tamper test to corrupt a byte that changes canonical output (e.g. the `issued` integer or insert whitespace), and/or strengthen step 6 to compare the presented payload bytes against the strict canonical form (presented != canonical ⇒ tampered).** The required, locked behavior: same-key + altered-payload ⇒ `.tampered`; foreign-key ⇒ `.invalid`; bad-structure ⇒ `.malformed`; good ⇒ `.valid`. Adjust the test's corruption target, not the four-way contract.

- [ ] **Step 5: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests
```

Expected: all four verification tests + the status test pass. If `tamperedPayloadIsTampered` fails because the corruption round-trips canonically, change the corruption to the `issued` field per the note above, re-run, and confirm green.

- [ ] **Step 6: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: offline Ed25519 LicenseVerifier (valid/invalid/tampered/malformed)"
```

(Append the standard trailer.)

---

### Task 7: `Feature` enum + tier→feature gating

Maps each agent (by its stable `Agent.id`) and each suite to a minimum tier. Pure table; no I/O.

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/Feature.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/FeatureGateTests.swift` (append)

- [ ] **Step 1: Write failing tests**

Append to `Packages/SenaniLicensing/Tests/SenaniLicensingTests/FeatureGateTests.swift`:

```swift
@Test func coreUnlocksCoreFeaturesButNotPro() {
    let core = LicenseTier.core
    #expect(core.unlocks(.triage))
    #expect(core.unlocks(.replyDrafter))
    #expect(core.unlocks(.booking))
    #expect(core.unlocks(.dailyDigest))
    #expect(core.unlocks(.inboxHygiene))
    // Pro sales suite is locked on Core:
    #expect(!core.unlocks(.leadQualifier))
    #expect(!core.unlocks(.proposalTracker))
    #expect(!core.unlocks(.followUp))
    #expect(!core.unlocks(.outreach))
    #expect(!core.unlocks(.invoiceFinance))
    #expect(!core.unlocks(.pipelineCRM))
}

@Test func proUnlocksEverything() {
    let pro = LicenseTier.pro
    for feature in Feature.allCases {
        #expect(pro.unlocks(feature), "Pro must unlock \(feature)")
    }
}

@Test func featureAgentIDsMatchAgentContract() {
    // The agent-backed features expose the SAME stable id Agent.id uses, so the
    // composition root can filter agents by `tier.unlocks(.init(agentID:))`.
    #expect(Feature(agentID: "lead-qualifier") == .leadQualifier)
    #expect(Feature(agentID: "triage") == .triage)
    #expect(Feature(agentID: "unknown-agent") == nil)
    #expect(Feature.leadQualifier.agentID == "lead-qualifier")
    #expect(Feature.pipelineCRM.agentID == nil)   // not an agent
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter FeatureGateTests
```

Expected: failure — `Feature` / `unlocks` undefined.

- [ ] **Step 3: Implement `Feature`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/Feature.swift`:

```swift
import Foundation

/// Gateable capabilities. Agent-backed cases carry the SAME stable id as the
/// corresponding `Agent.id` so the composition root can filter the agent list by
/// tier. `pipelineCRM` is a UI surface (Phase 3), not an agent.
public enum Feature: String, Sendable, CaseIterable {
    // Core ($99) — Roadmap Phases 1–2
    case triage
    case replyDrafter
    case booking
    case dailyDigest
    case inboxHygiene
    // Pro ($199) — Roadmap Phase 3 sales suite
    case leadQualifier
    case proposalTracker
    case followUp
    case outreach
    case invoiceFinance
    case pipelineCRM

    /// The minimum tier that unlocks this feature.
    public var minimumTier: LicenseTier {
        switch self {
        case .triage, .replyDrafter, .booking, .dailyDigest, .inboxHygiene:
            return .core
        case .leadQualifier, .proposalTracker, .followUp, .outreach, .invoiceFinance, .pipelineCRM:
            return .pro
        }
    }

    /// Stable `Agent.id` for agent-backed features; nil for non-agent surfaces.
    public var agentID: String? {
        switch self {
        case .triage:           return "triage"
        case .replyDrafter:     return "reply-drafter"
        case .booking:          return "booking"
        case .dailyDigest:      return "daily-digest"
        case .inboxHygiene:     return "inbox-hygiene"
        case .leadQualifier:    return "lead-qualifier"
        case .proposalTracker:  return "proposal-tracker"
        case .followUp:         return "follow-up"
        case .outreach:         return "outreach"
        case .invoiceFinance:   return "invoice-finance"
        case .pipelineCRM:      return nil
        }
    }

    /// Reverse lookup from a stable agent id.
    public init?(agentID: String) {
        guard let match = Feature.allCases.first(where: { $0.agentID == agentID }) else { return nil }
        self = match
    }
}

public extension LicenseTier {
    /// True iff this tier meets or exceeds the feature's minimum tier.
    func unlocks(_ feature: Feature) -> Bool {
        self >= feature.minimumTier
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter FeatureGateTests
```

Expected: all FeatureGate tests pass (tier ordering + core-locks-pro + pro-unlocks-all + id mapping).

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: Feature enum + tier→feature gating table"
```

(Append the standard trailer.)

---

### Task 8: `EmbeddedPublicKey` + `LicenseVerifier.senani()` factory

The app needs a verifier with the real embedded public key. This file holds the **public** key only (base64) and a factory. The placeholder is replaced by the human after running the offline `gen-key` (Task 10). Embedding the public key in source is safe and is the standard offline-licensing approach.

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/EmbeddedPublicKey.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseVerifierTests.swift` (append)

- [ ] **Step 1: Write a failing test**

Append to `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseVerifierTests.swift`:

```swift
@Test func embeddedPublicKeyParsesInto32Bytes() throws {
    // The embedded base64 must decode to a 32-byte Ed25519 public key (or be the
    // documented placeholder, which still must be 32 bytes so the app never crashes).
    let key = try EmbeddedPublicKey.publicKey()
    #expect(key.rawRepresentation.count == 32)
}

@Test func senaniFactoryBuildsAVerifier() throws {
    let verifier = try LicenseVerifier.senani()
    // A random key string is malformed under any public key — proves the verifier runs.
    #expect(verifier.verify("ZZZZZ-ZZZZZ") == .malformed || verifier.verify("ZZZZZ-ZZZZZ") == .invalid)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests
```

Expected: failure — `EmbeddedPublicKey` / `LicenseVerifier.senani()` undefined.

- [ ] **Step 3: Implement `EmbeddedPublicKey`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/EmbeddedPublicKey.swift`:

```swift
import Foundation
import CryptoKit

/// The app's embedded Ed25519 PUBLIC key (base64 of the 32-byte raw representation).
/// The PRIVATE key NEVER appears here or anywhere in the repo — it lives only on the
/// seller's offline machine. Replace this base64 with the output of:
///     swift Scripts/sign_license.swift gen-key
/// (the script prints the public-key base64 to embed and writes the private key to a
/// file you keep OFFLINE — see Scripts/README-licensing.md).
public enum EmbeddedPublicKey {
    /// PLACEHOLDER: a base64-encoded 32-byte all-zero key. The app loads/verifies
    /// against it without crashing, but every real key reports `.invalid` until the
    /// human embeds the production public key. Tests use their own in-test keypair,
    /// so this placeholder never blocks the suite.
    public static let base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    enum KeyError: Error { case badEncoding, wrongLength }

    public static func publicKey() throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: base64) else { throw KeyError.badEncoding }
        guard data.count == 32 else { throw KeyError.wrongLength }
        return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
}

public extension LicenseVerifier {
    /// The production verifier using the embedded public key.
    static func senani() throws -> LicenseVerifier {
        LicenseVerifier(publicKey: try EmbeddedPublicKey.publicKey())
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests
```

Expected: all verifier tests pass (the all-zero placeholder is a valid 32-byte key for parsing; real keys report `.invalid` against it, which is correct).

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: embedded public key placeholder + LicenseVerifier.senani() factory"
```

(Append the standard trailer.)

---

### Task 9: `LicenseKeychainStore` — persist the activated key (macOS Keychain)

Stores the activated key STRING in the Keychain (a generic-password item). Verification still runs on load — we never trust a stored tier without re-verifying. The store does no crypto; it only persists/loads/clears the raw key string.

**Files:**
- Create: `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseKeychainStore.swift`
- Test: `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseKeychainStoreTests.swift` (new)

- [ ] **Step 1: Write failing tests**

Create `Packages/SenaniLicensing/Tests/SenaniLicensingTests/LicenseKeychainStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniLicensing

@Test func saveLoadClearRoundTrips() throws {
    // Use a unique service per run so concurrent test runs don't collide.
    let service = "in.quantana.senani.license.test.\(UUID().uuidString)"
    let store = LicenseKeychainStore(service: service)
    defer { try? store.clear() }

    #expect(try store.load() == nil)             // empty to start
    try store.save("ABCDE-FGHIJ-KLMNP")
    #expect(try store.load() == "ABCDE-FGHIJ-KLMNP")
    try store.save("NEWKE-Y0001")                // overwrite, not duplicate
    #expect(try store.load() == "NEWKE-Y0001")
    try store.clear()
    #expect(try store.load() == nil)             // cleared
}
```

> **Worker note:** Keychain access from a SwiftPM test binary on macOS works for generic-password items without entitlements, but can prompt or fail in fully sandboxed CI. If `swift test` cannot reach the Keychain in the worktree, mark this test `.disabled("requires macOS Keychain access")` and verify manually with `swift run` from the app, recording the limitation — do NOT replace the Keychain with a file. The pure crypto tests (Tasks 4–8) are the gating suite; this one is environment-dependent.

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniLicensing && swift test --filter LicenseKeychainStoreTests
```

Expected: failure — `LicenseKeychainStore` undefined.

- [ ] **Step 3: Implement `LicenseKeychainStore`**

Create `Packages/SenaniLicensing/Sources/SenaniLicensing/LicenseKeychainStore.swift`:

```swift
import Foundation
import Security

/// Persists the activated license-key STRING in the macOS Keychain as a generic
/// password. No crypto here — the verifier re-checks the key on load, so a stolen
/// stored string is worthless without a real signature. No network, ever.
public struct LicenseKeychainStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "in.quantana.senani.license",
                account: String = "activated-key") {
        self.service = service
        self.account = account
    }

    enum KeychainError: Error { case unexpectedStatus(OSStatus), badData }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        // Delete any existing item first, then add — simplest correct "upsert".
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.badData
        }
        return key
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniLicensing && swift test --filter LicenseKeychainStoreTests
```

Expected: round-trip test passes (or is `.disabled` per the worker note, with the rest of the suite green).

- [ ] **Step 5: Commit**

```
cd Packages/SenaniLicensing && git add -A && git commit -m "SenaniLicensing: LicenseKeychainStore (save/load/clear the activated key)"
```

(Append the standard trailer.)

---

### Task 10: Offline seller-side signer `Scripts/sign_license.swift` + key-custody doc

This script runs ONLY on the seller's offline machine. It (a) generates a keypair and prints the public key to embed (private key written to a file the human keeps offline), and (b) signs a payload into a license key. It is NOT part of the app target and NEVER imports the package — it re-implements the exact same byte layout so the two stay independent, and a smoke test proves a script-signed key verifies in the package.

**Files:**
- Create: `Scripts/sign_license.swift`
- Create: `Scripts/README-licensing.md`
- Test: a one-shot smoke check run from the repo root (documented below; optional CI step).

- [ ] **Step 1: Implement the signer script**

Create `Scripts/sign_license.swift`:

```swift
#!/usr/bin/env swift
// OFFLINE seller-side license tool. Run ONLY on a machine that is OFF the network
// when handling the private key. NEVER commit the private key. Usage:
//
//   swift Scripts/sign_license.swift gen-key [out-private-key-path]
//       → generates an Ed25519 keypair. Prints the PUBLIC key base64 to paste into
//         Sources/SenaniLicensing/EmbeddedPublicKey.swift. Writes the PRIVATE key
//         base64 to the given path (default ./senani-license-private.key) — KEEP OFFLINE.
//
//   swift Scripts/sign_license.swift sign <private-key-path> <licenseID> <core|pro> [email] [seats]
//       → prints a XXXXX-XXXXX-... license key to hand to the buyer.
//
// The byte layout MUST match LicenseVerifier: tag(0x01) ‖ canonicalPayloadJSON ‖ sig(64),
// base32-grouped (Crockford). This file intentionally re-implements the codec so the
// signer never imports the app package.

import Foundation
import CryptoKit

let tag: UInt8 = 0x01
let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

func base32Group(_ data: Data) -> String {
    var bits = 0, value = 0
    var symbols = ""
    for byte in data {
        value = (value << 8) | Int(byte); bits += 8
        while bits >= 5 { bits -= 5; symbols.append(crockford[(value >> bits) & 0x1F]) }
    }
    if bits > 0 { symbols.append(crockford[(value << (5 - bits)) & 0x1F]) }
    var grouped = ""
    for (i, ch) in symbols.enumerated() {
        if i > 0 && i % 5 == 0 { grouped.append("-") }
        grouped.append(ch)
    }
    return grouped
}

func canonicalPayload(licenseID: String, tier: String, issued: Int,
                      email: String?, seats: Int?) -> Data {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    var fields: [(String, String)] = [
        ("issued", String(issued)),
        ("licenseID", "\"\(esc(licenseID))\""),
        ("tier", "\"\(esc(tier))\""),
    ]
    if let email { fields.append(("buyerEmail", "\"\(esc(email))\"")) }
    if let seats { fields.append(("seats", String(seats))) }
    fields.sort { $0.0 < $1.0 }
    let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
    return Data("{\(body)}".utf8)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    FileHandle.standardError.write(Data("usage: gen-key | sign\n".utf8)); exit(2)
}

switch cmd {
case "gen-key":
    let priv = Curve25519.Signing.PrivateKey()
    let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
    let privB64 = priv.rawRepresentation.base64EncodedString()
    let outPath = args.count > 1 ? args[1] : "./senani-license-private.key"
    try privB64.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("PUBLIC KEY (paste into EmbeddedPublicKey.base64):")
    print(pubB64)
    print("PRIVATE KEY written to \(outPath) — KEEP OFFLINE, NEVER COMMIT.")

case "sign":
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("usage: sign <priv-path> <id> <core|pro> [email] [seats]\n".utf8)); exit(2)
    }
    let privPath = args[1], licenseID = args[2], tier = args[3]
    guard tier == "core" || tier == "pro" else {
        FileHandle.standardError.write(Data("tier must be core or pro\n".utf8)); exit(2)
    }
    let email = args.count > 4 && !args[4].isEmpty ? args[4] : nil
    let seats = args.count > 5 ? Int(args[5]) : nil
    let privB64 = try String(contentsOfFile: privPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let privData = Data(base64Encoded: privB64) else {
        FileHandle.standardError.write(Data("bad private key file\n".utf8)); exit(1)
    }
    let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)
    let issued = Int(Date().timeIntervalSince1970)
    let payload = canonicalPayload(licenseID: licenseID, tier: tier,
                                   issued: issued, email: email, seats: seats)
    var signed = Data([tag]); signed.append(payload)
    let sig = try priv.signature(for: signed)
    var keyBytes = signed; keyBytes.append(sig)
    print(base32Group(keyBytes))

default:
    FileHandle.standardError.write(Data("unknown command: \(cmd)\n".utf8)); exit(2)
}
```

- [ ] **Step 2: Smoke-test the script end-to-end (manual / optional CI)**

From the repo root:

```
swift Scripts/sign_license.swift gen-key /tmp/senani-test-priv.key
# copy the printed PUBLIC KEY base64
swift Scripts/sign_license.swift sign /tmp/senani-test-priv.key LIC-TEST pro buyer@example.com 1
# copy the printed XXXXX-XXXXX key
```

Then prove the package verifies it: temporarily paste the printed public-key base64 into `EmbeddedPublicKey.base64`, add a throwaway test that calls `LicenseVerifier.senani().verify("<printed key>")` and expects `.valid(.pro)`, run `cd Packages/SenaniLicensing && swift test --filter LicenseVerifierTests`, confirm green, then **revert** the public key to the placeholder and delete the throwaway test. Do NOT commit `/tmp/senani-test-priv.key` or any private key.

Expected: the script-signed key verifies as `.valid(.pro)` — proving the signer and verifier share the exact byte layout.

- [ ] **Step 3: Write the key-custody doc**

Create `Scripts/README-licensing.md`:

```markdown
# License-Key Custody (OFFLINE)

Senani license keys are signed offline with Ed25519. The app embeds only the PUBLIC
key and verifies signatures with no network, no accounts, no telemetry.

## Key custody — non-negotiable
- The PRIVATE key is generated and used ONLY on a seller machine that is OFF the
  network when the key file is present. It is NEVER committed, NEVER in the app
  bundle, NEVER in this repo, and NEVER emailed.
- Store the private-key file (`senani-license-private.key`, base64 of the 32-byte
  raw key) in an encrypted, backed-up vault (e.g. a password manager / offline
  encrypted volume). Losing it means you can no longer sign keys (rotate — below).
- The PUBLIC key is safe to embed in source: it can only VERIFY, never sign.

## Generate the keypair (once)
    swift Scripts/sign_license.swift gen-key ~/secure/senani-license-private.key
Paste the printed PUBLIC KEY base64 into
`Packages/SenaniLicensing/Sources/SenaniLicensing/EmbeddedPublicKey.swift` (the
`base64` constant), commit THAT (public) change, and store the private key offline.

## Sign a license for a buyer
    swift Scripts/sign_license.swift sign ~/secure/senani-license-private.key \
        LIC-2026-0007 pro buyer@example.com 1
Hand the printed `XXXXX-XXXXX-...` key to the buyer (with their purchase receipt).

## Rotation
If the private key is ever exposed: generate a new keypair, embed the new public key
in a new app release, and re-issue keys to existing buyers. Old keys verify only
against the old public key, so a rotated build invalidates leaked keys. There is no
revocation list (that would need a server, which the trust model forbids) — rotation
via an app update is the offline-safe mechanism.

## What the app does
On launch / activation the app reads the stored key from the Keychain and calls
`LicenseVerifier.senani().verify(key)`. `.valid(tier)` gates features per `Feature`.
No network call is ever made for licensing.
```

- [ ] **Step 4: Ensure private keys can never be committed**

Confirm `.gitignore` excludes private keys. From the repo root, verify (and add if missing) these lines in `/Users/vishalkumar/Downloads/qmail/.gitignore`:

```
*.key
senani-license-private.key
```

(Use the Read tool to inspect `.gitignore`, then the Edit tool to append the two lines if absent. Do not duplicate existing entries.)

- [ ] **Step 5: Commit**

```
cd /Users/vishalkumar/Downloads/qmail && git add Scripts/sign_license.swift Scripts/README-licensing.md .gitignore && git commit -m "Scripts: offline Ed25519 license signer + key-custody doc + gitignore private keys"
```

(Append the standard trailer.)

---

### Task 11: Wire tier gating into `AppEnvironment` + `LicenseState` + activation-screen stub

The single gating seam: `AppEnvironment` holds a `LicenseState` (Keychain + verifier) and **filters the agent list by tier before building `AgentRegistry`**. UI is limited to an activation stub.

**Files:**
- Edit: `SenaniApp/Package.swift` (add the `SenaniLicensing` path dependency)
- Create: `SenaniApp/Sources/SenaniApp/License/LicenseState.swift`
- Create: `SenaniApp/Sources/SenaniApp/License/ActivationView.swift`
- Edit: `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`
- Test: `SenaniApp/Tests/SenaniAppTests/LicenseGatingTests.swift` (new)

> **Build-order dependency:** this task requires the app-shell plan's `AppEnvironment` to exist. If the worktree still has the scaffold `AppState`, record the dependency and either (a) complete the app-shell migration first, or (b) attach `LicenseState` to whatever injection type shipped and gate the registry there. Do NOT introduce a third injection type. The code below is the `AppEnvironment` form; adapt to the real built type.

- [ ] **Step 1: Add the package dependency**

In `SenaniApp/Package.swift`, add `.package(path: "Packages/SenaniLicensing")` to `dependencies` and `.product(name: "SenaniLicensing", package: "SenaniLicensing")` to both the app target and the test target's dependency lists (match the existing path style the manifest already uses for `SenaniRules` etc.). Use Read then Edit.

- [ ] **Step 2: Write failing gating tests**

Create `SenaniApp/Tests/SenaniAppTests/LicenseGatingTests.swift`:

```swift
import Testing
import SenaniLicensing
@testable import SenaniApp

@Test func licenseStateGatesByTier() {
    // No key → unlicensed → unlocks nothing.
    let unlicensed = LicenseState(status: .invalid)
    #expect(!unlicensed.unlocks(.triage))
    #expect(!unlicensed.unlocks(.leadQualifier))

    let core = LicenseState(status: .valid(.core))
    #expect(core.unlocks(.triage))
    #expect(!core.unlocks(.leadQualifier))

    let pro = LicenseState(status: .valid(.pro))
    #expect(pro.unlocks(.triage))
    #expect(pro.unlocks(.leadQualifier))
}

@Test func enabledAgentIDsReflectTier() {
    let core = LicenseState(status: .valid(.core))
    let all = ["triage", "reply-drafter", "booking", "daily-digest",
               "inbox-hygiene", "lead-qualifier", "proposal-tracker",
               "follow-up", "outreach", "invoice-finance"]
    let enabled = all.filter { core.enablesAgent(id: $0) }
    #expect(enabled.contains("triage"))
    #expect(!enabled.contains("lead-qualifier"))
}
```

- [ ] **Step 3: Run to fail**

```
cd SenaniApp && swift test --filter LicenseGatingTests
```

Expected: failure — `LicenseState` undefined.

- [ ] **Step 4: Implement `LicenseState`**

Create `SenaniApp/Sources/SenaniApp/License/LicenseState.swift`:

```swift
import Foundation
import SwiftUI
import SenaniLicensing

/// App-tier adapter binding the Keychain-stored key to the offline verifier and
/// exposing tier-based gating to the composition root and UI. The ONLY place the
/// app touches licensing. No network.
@MainActor
public final class LicenseState: ObservableObject {
    @Published public private(set) var status: LicenseStatus

    private let verifier: LicenseVerifier
    private let store: LicenseKeychainStore

    /// Test/preview seam: inject a status directly.
    public init(status: LicenseStatus) {
        self.status = status
        self.verifier = (try? LicenseVerifier.senani()) ?? LicenseVerifier(
            publicKey: (try? EmbeddedPublicKey.publicKey())!)
        self.store = LicenseKeychainStore()
    }

    /// Live: verify whatever key is stored in the Keychain (offline).
    public init(verifier: LicenseVerifier? = nil, store: LicenseKeychainStore = .init()) {
        self.verifier = verifier ?? ((try? LicenseVerifier.senani())
            ?? LicenseVerifier(publicKey: (try? EmbeddedPublicKey.publicKey())!))
        self.store = store
        if let stored = try? store.load() {
            self.status = self.verifier.verify(stored)
        } else {
            self.status = .invalid   // unlicensed
        }
    }

    public var tier: LicenseTier? { status.tier }

    /// Activate a typed key: verify offline; persist only if valid.
    public func activate(_ key: String) {
        let result = verifier.verify(key)
        status = result
        if result.tier != nil { try? store.save(key) }
    }

    public func deactivate() {
        try? store.clear()
        status = .invalid
    }

    public func unlocks(_ feature: Feature) -> Bool {
        guard let tier else { return false }
        return tier.unlocks(feature)
    }

    /// Whether an agent (by stable id) is enabled under the current tier. Unknown
    /// ids default to disabled (fail-closed).
    public func enablesAgent(id: String) -> Bool {
        guard let feature = Feature(agentID: id) else { return false }
        return unlocks(feature)
    }
}
```

- [ ] **Step 5: Run to pass**

```
cd SenaniApp && swift test --filter LicenseGatingTests
```

Expected: both gating tests pass.

- [ ] **Step 6: Add `licenseState` to `AppEnvironment` and filter agents by tier**

In `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`:
1. `import SenaniLicensing` at the top.
2. Add a stored property `public let licenseState: LicenseState` and accept it in the private `init` (thread it through both `live()` and `preview()`).
3. In `live()`, build `let licenseState = LicenseState()` (reads Keychain). In `preview()`, build `let licenseState = LicenseState(status: .valid(.pro))` so previews show everything.
4. In `makeEngine(...)`, accept the `licenseState` and filter the agent list before constructing `AgentRegistry`:

```swift
// Phase 0 still bootstraps with no agents; once Triage/Reply-Drafter/etc. register,
// the registry is built from ONLY the agents the current tier unlocks. The gate is
// here, in the composition root — the single safety/entitlement seam (reconciliation §4).
let allAgents: [any Agent] = []   // future plans append their agents here
let enabledAgents = allAgents.filter { licenseState.enablesAgent(id: $0.id) }
let registry = AgentRegistry(agents: enabledAgents)
```

Keep the `NoopAgent` triage argument as-is (triage is Core and always allowed; the filter applies to the registry list, not the required triage arg). Record in a code comment that future agent plans register through `allAgents` so the gate stays centralized.

> If `AppEnvironment.makeEngine` does not yet take agents (Phase-0 empty), add the `licenseState` parameter and the filter scaffold now so later agent plans plug into a gate that already exists. The filter over an empty list is a no-op today and correct.

- [ ] **Step 7: Implement the activation-screen stub**

Create `SenaniApp/Sources/SenaniApp/License/ActivationView.swift`:

```swift
import SwiftUI
import SenaniLicensing

/// STUB activation screen: paste a key, Activate, see status. The full Settings →
/// License management UI (receipts, deactivate, upgrade-to-Pro upsell) is deferred.
public struct ActivationView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var key: String = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activate Senani").font(.title2).bold()
            Text("Paste your license key. Verification is fully offline — no account, no internet.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("XXXXX-XXXXX-XXXXX-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("Activate") { env.licenseState.activate(key) }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                statusLabel
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }

    @ViewBuilder private var statusLabel: some View {
        switch env.licenseState.status {
        case .valid(let tier): Label("Activated — \(tier.rawValue.capitalized)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .invalid:         Label("Invalid key", systemImage: "xmark.seal").foregroundStyle(.red)
        case .tampered:        Label("Tampered key", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .malformed:       Label("Not a valid key format", systemImage: "questionmark.diamond").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ActivationView().environmentObject(AppEnvironment.preview())
}
```

- [ ] **Step 8: Build + run the full app test suite**

```
cd SenaniApp && swift build && swift test
```

Expected: the app builds (SwiftUI compiles), `LicenseGatingTests` + the existing `AppEnvironmentTests` pass, and `preview()` now includes a Pro `licenseState`. Resolve any `Sendable`/concurrency warnings.

- [ ] **Step 9: Commit**

```
cd SenaniApp && git add -A && git commit -m "SenaniApp: wire tier gating into AppEnvironment (LicenseState) + activation-screen stub"
```

(Append the standard trailer.)

---

### Task 12: Full suite green + final commit

**Files:** none (verification).

- [ ] **Step 1: Run the package suite**

```
cd Packages/SenaniLicensing && swift test
```

Expected: ALL tests pass across `Base32GroupedTests`, `LicensePayloadCodecTests`, `LicenseVerifierTests`, `FeatureGateTests`, and `LicenseKeychainStoreTests` (the Keychain test may be `.disabled` on a sandboxed CI — note it if so).

- [ ] **Step 2: Build clean under strict concurrency**

```
cd Packages/SenaniLicensing && swift build
```

Expected: builds with no errors and no `Sendable`/concurrency warnings.

- [ ] **Step 3: App suite green**

```
cd SenaniApp && swift test
```

Expected: app builds and all app tests (including `LicenseGatingTests`) pass.

- [ ] **Step 4: Final commit (if anything changed)**

```
cd /Users/vishalkumar/Downloads/qmail && git add -A && git commit -m "SenaniLicensing: offline one-time license keys — full feature green"
```

(Append the standard trailer.)

---

## Self-Review

**Scope coverage (ROADMAP "One-time license keys (offline verification)"):**
- **Asymmetric Ed25519, public key embedded, private key offline-only** — `LicenseVerifier` holds only a `Curve25519.Signing.PublicKey`; `EmbeddedPublicKey` is public-only; the private key exists solely in `Scripts/sign_license.swift`'s `gen-key` output, written to a file the human keeps offline and `.gitignore`d. ✅ (Tasks 6, 8, 10)
- **Compact base32-grouped `XXXXX-XXXXX` key encoding a license id + tier + issue date + optional email/seat, signed** — `LicensePayload` defines the exact struct + canonical deterministic JSON; `Base32Grouped` defines the exact `tag ‖ payload ‖ sig(64)` Crockford encoding. ✅ (Tasks 3, 4)
- **`SenaniLicensing` package with `LicensePayload`, `LicenseVerifier(publicKey:).verify(_:) -> LicenseStatus` (`.valid(tier)/.invalid/.tampered/.malformed`)** — exactly as pinned. ✅ (Tasks 5, 6)
- **Tier→feature gating, Pro-suite agents map to `.pro`** — `Feature` + `LicenseTier.unlocks(_:)`; `lead-qualifier/proposal-tracker/follow-up/outreach/invoice-finance/pipelineCRM` are `.pro`, the rest `.core`. ✅ (Task 7)
- **Activated key stored in the Keychain; NO network/server/phone-home** — `LicenseKeychainStore` (generic password, `*ThisDeviceOnly`); zero networking anywhere in the plan. ✅ (Task 9)
- **Tier gating wired into `AppEnvironment` (which agents are available) + activation-screen stub** — `LicenseState` adapter filters the agent list before `AgentRegistry`; `ActivationView` stub; deeper UI deferred. ✅ (Task 11)

**Tests (pure, deterministic, in-test keypair):**
- valid key (right tier) → `.valid(.core)` / `.valid(.pro)`; tampered → `.tampered`; wrong-key signature → `.invalid`; malformed string → `.malformed`. ✅ (Task 6 `LicenseVerifierTests`)
- Core does NOT unlock Pro features; Pro unlocks all. ✅ (Task 7 `FeatureGateTests`)
- The keypair is generated **in-test** (`Curve25519.Signing.PrivateKey()` in `SignerHelper`); no real key committed. ✅
- No network in any test. ✅

**Conventions honored (reconciliation §4):** composition-root-only gating (the agent filter lives in `AppEnvironment.makeEngine`, not in screens); one entitlement seam; macOS 14 / Swift 6.2 / Swift Testing; TDD bite-sized steps with failing→passing→commit; full code, no placeholders (the only "placeholder" is the embedded public-key constant, which is documented and replaced by the human via `gen-key`).

**Tampered-vs-invalid honest caveat:** Ed25519 cannot intrinsically tell "altered payload" from "foreign signature" — both are just a failed verify. Task 6 implements a deterministic disambiguation (re-canonicalize the parsed payload: bytes differ ⇒ `.tampered`, bytes identical but signature fails ⇒ `.invalid`) and the test corruption target is chosen to make the mapping unambiguous. The note in Task 6 Step 4 instructs the worker to adjust the test's corruption byte (not the four-way contract) if a particular edit round-trips canonically. The security guarantee is unchanged: only a signature from the embedded public key's matching private key yields `.valid`; everything else is denied.

**Contracts exposed (public API of `SenaniLicensing`):** `LicenseTier`, `LicensePayload`, `LicenseStatus`, `LicenseVerifier` (+ `.senani()`), `Feature` (+ `LicenseTier.unlocks(_:)`), `LicenseKeychainStore`, `EmbeddedPublicKey`. App-tier: `LicenseState`, `ActivationView`, `AppEnvironment.licenseState`.

**Explicitly deferred to separate plans:** code signing/notarization; auto-update; purchase/checkout + key delivery; full Settings → License UI (receipts/deactivate/upgrade upsell); per-feature paywall copy; the `outreach`/`invoice-finance` agent implementations (their ids are pre-pinned here so the gate is complete).

**Risks / assumptions to confirm with the human before/while coding:**
1. **`AppEnvironment` exists** (app-shell plan landed) — Task 11 depends on it and on `makeEngine` taking the agent list; if only the scaffold `AppState` is present, complete the migration or attach `LicenseState` to the shipped type (no third injection type).
2. **Keychain access from `swift test`** — works for generic-password items on a real macOS session; may need `.disabled` in sandboxed CI. The gating crypto suite (Tasks 4–8) is environment-independent.
3. **Embedded public key** — the placeholder all-zero key makes every real key `.invalid` until the human runs `gen-key` and pastes the production public key (reconciliation §5: "license-key keypair … supplied by the human").
4. **Agent ids** — `outreach`/`invoice-finance` plans are not yet written; this plan pins their ids (`outreach`, `invoice-finance`). If those plans choose different ids, update `Feature.agentID` in the same commit.
