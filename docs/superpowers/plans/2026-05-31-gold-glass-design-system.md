# SenaniDesign — Gold-Glass Design System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `SenaniDesign` — the reusable SwiftUI **design system** every Senani screen imports: the gold-glass visual language (color tokens, fonts), a frosted gold-edged `GlassPanel` container, a `CategoryChip` (Lead / Booking / Proposal style chips from the landing mock), a `PrimaryButton` (the gold-gradient CTA), and the `AutonomyDial` (a Suggest → Draft → Auto segmented control that binds `SenaniRules.Autonomy`). Concrete color/font values are derived directly from the brand's landing page (`landing/index.html`). Views are validated by **snapshot-free, deterministic unit tests** that drive the *pure logic seams* extracted out of each view (label maps, color resolution, binding round-trips), plus a `#Preview` for every component. No MLX, Gmail, store, or app-shell dependency.

**Architecture:** A new **local Swift package** `Packages/SenaniDesign` — a peer of the engine packages, not an app-internal module. Rationale: a package gives it (1) its own `swift test` target so the design system is verified in isolation and in CI exactly like the nine frozen engine packages, (2) a clean public-API boundary (`import SenaniDesign`) that ~6 downstream UI plans depend on, and (3) a single upstream dependency it can pin — `SenaniRules` — for the one type it must bind, `Autonomy`. The package depends ONLY on `SwiftUI` (system) and `SenaniRules` (path dependency, frozen). It never imports `SenaniStore`, `SenaniInference`, `SenaniGmail`, or the app shell — those flow the other direction.

The design discipline throughout: **every view has a pure, testable logic seam.** SwiftUI `View` bodies are not unit-testable without a snapshot/inspection framework (we use neither), so each component delegates its decisions (which label, which color, what the next/previous segment is, how a `Color` is constructed from hex) to a free function or a small `Sendable` value type that IS unit-tested. The `View` is then a thin shell over verified logic. This is the same "agents are pure, views are thin" altitude the app-plans reconciliation §4 mandates.

**Tech Stack:** Swift 6.2 (strict concurrency, `swift-tools-version: 6.0`), Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain). Target platform macOS 14 (`.macOS(.v14)`). SwiftUI for views. **No** ViewInspector, **no** snapshot library, **no** MLX/Gmail/store/UI-app dependency.

**Working directory:** All `swift` commands run from `Packages/SenaniDesign/` unless stated otherwise.

**Source-of-truth docs:**
- `docs/superpowers/plans/2026-05-31-APP-PLANS-RECONCILIATION.md` — **§3 "DesignSystem"** pins the public symbol names this package owns; **§4** the conventions. AUTHORITATIVE.
- `docs/ARCHITECTURE.md` — the "gold-glass UI" language and the trust model the `AutonomyDial` expresses (Suggest → Draft → Auto-with-guardrails).
- `landing/index.html` — the brand's existing gold/glass CSS; every concrete color and font in this plan is mined from its `:root` custom properties (see Cross-package assumptions). `assets/senani-logo.svg` and `brand/index.html` reuse the same palette.

**Out of scope (separate plans):** the `AppEnvironment` composition root; any screen (Inbox cockpit, Approval queue, Activity log, Settings, Assistant panel); icon/illustration assets beyond what SF Symbols and the system provide; animation polish (the landing page's GSAP motion is web-only — SwiftUI components here are static/state-driven, no decorative animation in Phase 0); dark/light theme switching (the brand is a single dark gold-glass theme — we ship that one theme).

---

## Cross-package assumptions (state these to the human before coding)

This package compiles against exactly one upstream contract and one brand artifact. Pin both.

- **`SenaniRules` (built + tested + frozen — do NOT edit):** the ONLY upstream code dependency. The `AutonomyDial` binds:
  ```swift
  public enum Autonomy: String, Sendable, Equatable { case ask; case prepare; case auto }
  ```
  **VERIFIED FROM SOURCE** (`Packages/SenaniRules/Sources/SenaniRules/Rule.swift`). **Critical deviation from the reconciliation/brief wording:** the reconciliation §3 and the Phase-0 brief describe the dial as `suggest → draft → auto` and §2 lists `enum Autonomy { case suggest, draft, auto }`. **The frozen enum's actual cases are `ask`, `prepare`, `auto`** (the source comment explains `prepare` was named to avoid colliding with the `draft(...)` action). Therefore: the dial **binds the real cases `.ask / .prepare / .auto`**, and renders the **display labels "Suggest" / "Draft" / "Auto"** over them (Suggest↔`.ask`, Draft↔`.prepare`, Auto↔`.auto`). This label/case mapping is the dial's pure logic seam and is the single load-bearing line coupling this package to `SenaniRules`. If a future re-freeze renames the cases, only `AutonomyOption` (Task 7) changes. **Surface this case-name mismatch to the human before coding** so the reconciliation doc can be corrected in the same spirit as §4 ("if an owner changes a signature, update this doc in the same commit").
  - The package depends on `SenaniRules` **only** for `Autonomy`. It does not touch `Action`, `Message`, `Rule`, or any store/backend type.

- **Brand palette (mined from `landing/index.html` `:root`, the authoritative brand source):** these exact hex values become the `Color`/`Font` tokens. Pin them:
  | Token | CSS var | Hex / value | SenaniDesign symbol |
  |-------|---------|-------------|---------------------|
  | gold base | `--gold` | `#d4af37` | `Gold.base` |
  | gold highlight | `--gold-bright` | `#f4dd95` | `Gold.highlight` |
  | gold shadow / deep | `--gold-deep` | `#9c7a2e` | `Gold.shadow` |
  | champagne (accent) | `--champagne` | `#e8c97a` | `Color.senaniAccent` |
  | ink (primary text) | `--ink` | `#ece7dc` | `Color.senaniInk` |
  | surface / app bg | `--bg` | `#08080b` | `Color.senaniSurface` |
  | muted text | `--muted` | `#9b948a` | `Color.senaniMuted` (extra, used by chips/buttons) |
  | glass fill | `--glass` | `rgba(255,255,255,.045)` | internal `GlassPanel` fill |
  | gold edge line | `--line` | `rgba(212,175,55,.16)` | internal `GlassPanel`/chip border |
  | gold gradient | `--gold-grad` | `linear-gradient(135deg,#f4dd95,#d4af37 45%,#9c7a2e)` | `Gold.gradient` (PrimaryButton fill) |

  Fonts (the page loads Fraunces / Cinzel / Hanken Grotesk from Google Fonts; a macOS app can't assume those are installed, so **the tokens map brand intent to safe system fallbacks**, and the plan documents the bundled-font upgrade path as a deferred item):
  | Token | Brand intent (CSS) | SenaniDesign value (system fallback) | SenaniDesign symbol |
  |-------|--------------------|--------------------------------------|---------------------|
  | title/display | `--display: Fraunces, Georgia, serif` | `.system(.title, design: .serif)` | `Font.senaniTitle` |
  | body | `--body: Hanken Grotesk, system-ui, sans` | `.system(.body, design: .default)` | `Font.senaniBody` |
  | mono | (code blocks in `.flow code`) | `.system(.body, design: .monospaced)` | `Font.senaniMono` |
  > **Deferred (flag to human):** to match the brand pixel-for-pixel, bundle the Fraunces/Cinzel/Hanken `.ttf` files in the package's `resources` and register them. That is a follow-up; Phase 0 ships the system-design fallbacks above so there is zero font-licensing/bundling work blocking the design system. The `Font.senani*` symbol names are stable across that upgrade.

- **No new `SenaniRules` API and no edits to any frozen package.** If anything here would require touching a frozen package, stop and surface it to the human (per reconciliation §5).

---

## File Structure

```
Packages/SenaniDesign/
  Package.swift
  Sources/SenaniDesign/
    Color+Hex.swift          # init(hex:) helper (pure, the seam color tokens are built from)
    Gold.swift               # enum Gold { base/highlight/shadow + gradient } — the gold gradient stops
    Tokens.swift             # extension Color { senaniInk/senaniSurface/senaniAccent/senaniMuted }
                             #   + extension Font { senaniTitle/senaniBody/senaniMono }
    GlassPanel.swift         # struct GlassPanel<Content: View>: View — frosted gold-glass container w/ gold edge
    CategoryChip.swift       # enum Category + struct CategoryChip: View (Lead/Booking/Proposal chips)
    PrimaryButton.swift      # struct PrimaryButton: View — gold-gradient CTA
    AutonomyDial.swift       # enum AutonomyOption (pure label/case map) + struct AutonomyDial: View (binds Autonomy)
    Previews.swift           # a #Preview gallery aggregating every component (plus per-file #Previews)
  Tests/SenaniDesignTests/
    ColorHexTests.swift
    GoldTokenTests.swift
    TokenTests.swift
    GlassPanelTests.swift
    CategoryTests.swift
    PrimaryButtonTests.swift
    AutonomyOptionTests.swift
```

Each file has one responsibility. Every `View` file pairs a thin SwiftUI shell with a pure value/function that its test target drives directly — no view is "tested" by rendering; it is proven correct by testing the seam it is built from, and confirmed to *compile and instantiate* by a construction test.

---

### Task 1: Package scaffold + SenaniRules path dependency

**Files:**
- Create: `Packages/SenaniDesign/Package.swift`
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/Color+Hex.swift` (temporary one-line marker so the target compiles)
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/ColorHexTests.swift` (import-only placeholder)

- [ ] **Step 1: Write a failing import test**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/ColorHexTests.swift`:

```swift
import Testing
@testable import SenaniDesign
import SenaniRules

@Test func packageImportsCompileAndLinkSenaniRules() {
    // Proves the package builds and links SenaniRules (the one upstream dep).
    let autonomy: SenaniRules.Autonomy = .ask
    #expect(autonomy == .ask)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test
```

Expected: failure — no `Package.swift` / no `SenaniDesign` target (`error: no such module` / manifest not found).

- [ ] **Step 3: Create the manifest with the SenaniRules path dep**

Create `Packages/SenaniDesign/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniDesign",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniDesign", targets: ["SenaniDesign"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
    ],
    targets: [
        .target(
            name: "SenaniDesign",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
            ]
        ),
        .testTarget(
            name: "SenaniDesignTests",
            dependencies: ["SenaniDesign"]
        ),
    ]
)
```

Create `Packages/SenaniDesign/Sources/SenaniDesign/Color+Hex.swift` with a single line so the target is non-empty:

```swift
// SenaniDesign — gold-glass design system. Color hex helper defined in Task 2.
import SwiftUI
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: package scaffold with SenaniRules path dep"
```

Use this commit trailer on EVERY commit in this plan:

```

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 2: Color(hex:) helper — the pure seam every token is built from

**Files:**
- Edit: `Packages/SenaniDesign/Sources/SenaniDesign/Color+Hex.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/ColorHexTests.swift`

Color tokens must come from the brand's exact hex strings (e.g. `#d4af37`). A SwiftUI `Color` can't be value-compared for equality in a test, but its **RGBA components** can — so the seam is a pure function `rgba(hex:) -> (r,g,b,a)` that the `Color(hex:)` initializer uses, and which the test asserts against. This keeps token correctness verifiable without rendering.

- [ ] **Step 1: Replace the placeholder test with a real failing test**

Replace `ColorHexTests.swift`:

```swift
import Testing
@testable import SenaniDesign
import SenaniRules

@Test func packageImportsCompileAndLinkSenaniRules() {
    let autonomy: SenaniRules.Autonomy = .ask
    #expect(autonomy == .ask)
}

@Test func parsesSixDigitHex() {
    let c = HexColor.rgba(hex: "#d4af37")
    #expect(abs(c.r - 212.0/255.0) < 0.001)
    #expect(abs(c.g - 175.0/255.0) < 0.001)
    #expect(abs(c.b - 55.0/255.0) < 0.001)
    #expect(c.a == 1.0)
}

@Test func parsesWithoutLeadingHash() {
    let c = HexColor.rgba(hex: "f4dd95")
    #expect(abs(c.r - 244.0/255.0) < 0.001)
    #expect(abs(c.g - 221.0/255.0) < 0.001)
    #expect(abs(c.b - 149.0/255.0) < 0.001)
}

@Test func parsesEightDigitHexWithAlpha() {
    let c = HexColor.rgba(hex: "#d4af3729")   // ~16% opacity gold (the --line color)
    #expect(abs(c.r - 212.0/255.0) < 0.001)
    #expect(abs(c.a - 41.0/255.0) < 0.001)
}

@Test func malformedHexFallsBackToOpaqueBlackNeverCrashes() {
    let c = HexColor.rgba(hex: "nonsense")
    #expect(c.r == 0 && c.g == 0 && c.b == 0 && c.a == 1.0)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter ColorHexTests
```

Expected: failure — `HexColor` undefined.

- [ ] **Step 3: Implement the pure parser + the Color initializer**

Replace `Sources/SenaniDesign/Color+Hex.swift`:

```swift
import SwiftUI

/// Pure, testable hex → RGBA parser. The seam color tokens are built from.
/// Accepts "#RRGGBB", "RRGGBB", "#RRGGBBAA", "RRGGBBAA". Malformed input
/// returns opaque black (never crashes) so a bad token degrades visibly, not fatally.
public enum HexColor {
    public static func rgba(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else {
            return (0, 0, 0, 1)
        }
        if s.count == 6 {
            let r = Double((value & 0xFF0000) >> 16) / 255.0
            let g = Double((value & 0x00FF00) >> 8) / 255.0
            let b = Double(value & 0x0000FF) / 255.0
            return (r, g, b, 1.0)
        } else {
            let r = Double((value & 0xFF000000) >> 24) / 255.0
            let g = Double((value & 0x00FF0000) >> 16) / 255.0
            let b = Double((value & 0x0000FF00) >> 8) / 255.0
            let a = Double(value & 0x000000FF) / 255.0
            return (r, g, b, a)
        }
    }
}

public extension Color {
    /// Brand-hex initializer (uses the pure HexColor seam).
    init(hex: String) {
        let c = HexColor.rgba(hex: hex)
        self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter ColorHexTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: pure Color(hex:) parser seam from brand hex strings"
```

(Append the standard trailer.)

---

### Task 3: Gold tokens (base / highlight / shadow + gradient)

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/Gold.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/GoldTokenTests.swift`

Pins the reconciliation §3 symbol: `enum Gold { static let base/highlight/shadow: Color }`, plus the `gradient` used by `PrimaryButton`. Values are the brand's `--gold` / `--gold-bright` / `--gold-deep`. The test proves the tokens resolve to the exact brand RGBA via the `HexColor` seam (a constant `hex` string per token that the test re-parses).

- [ ] **Step 1: Write a failing token test**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/GoldTokenTests.swift`:

```swift
import Testing
@testable import SenaniDesign

@Test func goldHexConstantsMatchBrandPalette() {
    // The brand source of truth: landing/index.html :root.
    #expect(Gold.baseHex == "#d4af37")
    #expect(Gold.highlightHex == "#f4dd95")
    #expect(Gold.shadowHex == "#9c7a2e")
}

@Test func goldBaseResolvesToBrandRGBA() {
    let c = HexColor.rgba(hex: Gold.baseHex)
    #expect(abs(c.r - 212.0/255.0) < 0.001)
    #expect(abs(c.g - 175.0/255.0) < 0.001)
    #expect(abs(c.b - 55.0/255.0) < 0.001)
}

@Test func gradientStopsRunHighlightToShadow() {
    // The CSS --gold-grad goes f4dd95 -> d4af37 (45%) -> 9c7a2e.
    #expect(Gold.gradientStops.first == Gold.highlightHex)
    #expect(Gold.gradientStops.last == Gold.shadowHex)
    #expect(Gold.gradientStops.count == 3)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter GoldTokenTests
```

Expected: failure — `Gold` undefined.

- [ ] **Step 3: Implement `Gold`**

Create `Sources/SenaniDesign/Gold.swift`:

```swift
import SwiftUI

/// The gold gradient stops (reconciliation §3). Hex values mined from
/// landing/index.html :root (--gold / --gold-bright / --gold-deep).
public enum Gold {
    // Hex constants are the testable seam; the Colors are derived from them.
    public static let baseHex = "#d4af37"        // --gold
    public static let highlightHex = "#f4dd95"   // --gold-bright
    public static let shadowHex = "#9c7a2e"      // --gold-deep

    public static let base = Color(hex: baseHex)
    public static let highlight = Color(hex: highlightHex)
    public static let shadow = Color(hex: shadowHex)

    /// Ordered stops for the 135° brand gradient (--gold-grad), highlight → base → shadow.
    public static let gradientStops = [highlightHex, baseHex, shadowHex]

    /// The brand gold gradient used by PrimaryButton and gold edges.
    /// 135° in CSS ≈ topLeading → bottomTrailing in SwiftUI.
    public static let gradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: highlight, location: 0.0),
            .init(color: base, location: 0.45),
            .init(color: shadow, location: 1.0),
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter GoldTokenTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: Gold tokens (base/highlight/shadow) + brand gradient"
```

(Append the standard trailer.)

---

### Task 4: Color + Font tokens (senaniInk/Surface/Accent/Muted, senaniTitle/Body/Mono)

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/Tokens.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/TokenTests.swift`

Pins the reconciliation §3 symbols: `extension Color { senaniInk/senaniSurface/senaniAccent }` (plus `senaniMuted`, used by chips/buttons) and `extension Font { senaniTitle/senaniBody/senaniMono }`. Color hex constants are exposed as a testable seam; fonts are constructed from system designs (the documented fallbacks) — fonts can't be RGBA-tested, so the test asserts each `Font` token simply *exists and is non-nil* (a construction guard) while the *color* tokens get the exact-RGBA treatment.

- [ ] **Step 1: Write a failing token test**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/TokenTests.swift`:

```swift
import Testing
import SwiftUI
@testable import SenaniDesign

@Test func colorTokenHexMatchesBrandPalette() {
    #expect(SenaniTokens.inkHex == "#ece7dc")
    #expect(SenaniTokens.surfaceHex == "#08080b")
    #expect(SenaniTokens.accentHex == "#e8c97a")
    #expect(SenaniTokens.mutedHex == "#9b948a")
}

@Test func surfaceTokenResolvesToNearBlackBrandBackground() {
    let c = HexColor.rgba(hex: SenaniTokens.surfaceHex)
    #expect(abs(c.r - 8.0/255.0) < 0.001)
    #expect(abs(c.g - 8.0/255.0) < 0.001)
    #expect(abs(c.b - 11.0/255.0) < 0.001)
}

@Test func colorTokensAreReachableViaExtension() {
    // Compile-time proof the public extension symbols exist (reconciliation §3 names).
    _ = Color.senaniInk
    _ = Color.senaniSurface
    _ = Color.senaniAccent
    _ = Color.senaniMuted
}

@Test func fontTokensAreReachableViaExtension() {
    _ = Font.senaniTitle
    _ = Font.senaniBody
    _ = Font.senaniMono
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter TokenTests
```

Expected: failure — `SenaniTokens` / the extensions undefined.

- [ ] **Step 3: Implement the tokens**

Create `Sources/SenaniDesign/Tokens.swift`:

```swift
import SwiftUI

/// Brand-hex constants (the testable seam). Mined from landing/index.html :root.
public enum SenaniTokens {
    public static let inkHex = "#ece7dc"      // --ink   (primary text)
    public static let surfaceHex = "#08080b"  // --bg    (app background)
    public static let accentHex = "#e8c97a"   // --champagne (accent)
    public static let mutedHex = "#9b948a"    // --muted (secondary text)
}

public extension Color {
    /// Primary text on dark surfaces.
    static let senaniInk = Color(hex: SenaniTokens.inkHex)
    /// The near-black app background.
    static let senaniSurface = Color(hex: SenaniTokens.surfaceHex)
    /// Champagne accent (highlights, active edges).
    static let senaniAccent = Color(hex: SenaniTokens.accentHex)
    /// Secondary / muted text.
    static let senaniMuted = Color(hex: SenaniTokens.mutedHex)
}

public extension Font {
    /// Display/title intent (brand: Fraunces serif). System serif fallback;
    /// upgrade to a bundled Fraunces face is a documented deferred item.
    static let senaniTitle = Font.system(.title, design: .serif).weight(.medium)
    /// Body intent (brand: Hanken Grotesk). System default sans fallback.
    static let senaniBody = Font.system(.body, design: .default)
    /// Monospace intent (brand: code blocks). System monospaced.
    static let senaniMono = Font.system(.body, design: .monospaced)
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter TokenTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: Color + Font tokens (senaniInk/Surface/Accent/Muted, senaniTitle/Body/Mono)"
```

(Append the standard trailer.)

---

### Task 5: GlassPanel — frosted gold-glass container with the gold edge

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/GlassPanel.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/GlassPanelTests.swift`

Pins the reconciliation §3 symbol `struct GlassPanel<Content: View>: View { init(@ViewBuilder content:) }`. Models the landing page's `.mock-card`: a rounded rect, a translucent white fill (`--glass`), a thin gold border (`--line`), `.ultraThinMaterial` for the frost, and a soft shadow. The pure seam is `GlassPanelStyle` — a value type holding the resolved corner radius, border width, border opacity, and fill opacity — which the test asserts against. The `View` consumes the style.

- [ ] **Step 1: Write a failing style test**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/GlassPanelTests.swift`:

```swift
import Testing
import SwiftUI
@testable import SenaniDesign

@Test func defaultGlassStyleMatchesBrandMockCard() {
    let s = GlassPanelStyle.default
    #expect(s.cornerRadius == 18)        // .mock-card border-radius:18px
    #expect(s.borderWidth == 1)          // 1px gold edge
    #expect(abs(s.borderOpacity - 0.16) < 0.001) // --line rgba alpha .16
    #expect(abs(s.fillOpacity - 0.045) < 0.001)  // --glass rgba alpha .045
}

@Test func compactGlassStyleHasTighterRadius() {
    let s = GlassPanelStyle.compact
    #expect(s.cornerRadius == 15)        // .agent card radius
    #expect(s.cornerRadius < GlassPanelStyle.default.cornerRadius)
}

@Test func glassPanelBuildsWithContent() {
    // Construction guard: the generic View instantiates with arbitrary content.
    let panel = GlassPanel { Text("hello") }
    _ = panel.body   // exercising body must not trap
}

@Test func glassPanelAcceptsExplicitStyle() {
    let panel = GlassPanel(style: .compact) { Color.clear }
    #expect(panel.style.cornerRadius == 15)
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter GlassPanelTests
```

Expected: failure — `GlassPanel` / `GlassPanelStyle` undefined.

- [ ] **Step 3: Implement `GlassPanelStyle` + `GlassPanel`**

Create `Sources/SenaniDesign/GlassPanel.swift`:

```swift
import SwiftUI

/// Pure, testable description of a glass panel's geometry/opacities,
/// derived from the landing page's .mock-card / .agent card CSS.
public struct GlassPanelStyle: Sendable, Equatable {
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat
    public var borderOpacity: Double   // gold edge alpha (--line)
    public var fillOpacity: Double     // translucent white fill (--glass)

    public init(cornerRadius: CGFloat, borderWidth: CGFloat,
                borderOpacity: Double, fillOpacity: Double) {
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderOpacity = borderOpacity
        self.fillOpacity = fillOpacity
    }

    /// The hero .mock-card style.
    public static let `default` = GlassPanelStyle(
        cornerRadius: 18, borderWidth: 1, borderOpacity: 0.16, fillOpacity: 0.045)
    /// The tighter .agent / .price card style.
    public static let compact = GlassPanelStyle(
        cornerRadius: 15, borderWidth: 1, borderOpacity: 0.16, fillOpacity: 0.045)
}

/// Frosted gold-glass container (reconciliation §3). A rounded rect with a
/// translucent white fill over .ultraThinMaterial frost, a thin gold edge,
/// and a soft drop shadow — the brand's .mock-card.
public struct GlassPanel<Content: View>: View {
    public let style: GlassPanelStyle
    private let content: Content

    public init(style: GlassPanelStyle = .default,
                @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(style.fillOpacity))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(Gold.base.opacity(style.borderOpacity),
                                  lineWidth: style.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
    }
}

#Preview("GlassPanel") {
    GlassPanel {
        VStack(alignment: .leading, spacing: 8) {
            Text("Senani · handled overnight").font(.senaniTitle).foregroundStyle(Color.senaniInk)
            Text("3 threads need a reply.").font(.senaniBody).foregroundStyle(Color.senaniMuted)
        }
        .padding(24)
    }
    .padding(40)
    .background(Color.senaniSurface)
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter GlassPanelTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: GlassPanel frosted gold-glass container with gold edge"
```

(Append the standard trailer.)

---

### Task 6: CategoryChip — Lead / Booking / Proposal chips

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/CategoryChip.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/CategoryTests.swift`

The landing mock shows colored pill chips: `c-lead` (gold), `c-book` (blue `#9db8ff`), `c-prop` (green `#84d8a4`). A downstream UI plan needs these to tag triaged messages. The pure seam is `enum Category` with a `palette` computed property returning testable `(fillHex, textHex, borderHex)`; the `CategoryChip` view renders a rounded capsule using that palette. The category set is open-ended in the product (10 agents), so `Category` includes the three styled cases from the mock plus a `.other(String)` fallback that reuses the gold style.

- [ ] **Step 1: Write a failing palette test**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/CategoryTests.swift`:

```swift
import Testing
import SwiftUI
@testable import SenaniDesign

@Test func leadChipUsesGoldPalette() {
    let p = Category.lead.palette
    #expect(p.textHex == Gold.highlightHex)   // c-lead text is --gold-bright
}

@Test func bookingChipUsesBluePalette() {
    let p = Category.booking.palette
    #expect(p.textHex == "#9db8ff")            // c-book
}

@Test func proposalChipUsesGreenPalette() {
    let p = Category.proposal.palette
    #expect(p.textHex == "#84d8a4")            // c-prop
}

@Test func unknownCategoryFallsBackToGold() {
    let p = Category.other("Invoice").palette
    #expect(p.textHex == Gold.highlightHex)
}

@Test func categoryTitleIsHumanReadable() {
    #expect(Category.lead.title == "Lead")
    #expect(Category.booking.title == "Booking")
    #expect(Category.proposal.title == "Proposal")
    #expect(Category.other("Invoice").title == "Invoice")
}

@Test func chipBuildsForEveryStyledCategory() {
    for c in [Category.lead, .booking, .proposal, .other("X")] {
        _ = CategoryChip(c).body
    }
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter CategoryTests
```

Expected: failure — `Category` / `CategoryChip` undefined.

- [ ] **Step 3: Implement `Category` + `CategoryChip`**

Create `Sources/SenaniDesign/CategoryChip.swift`:

```swift
import SwiftUI

/// A triage category surfaced as a colored chip (landing mock: Lead/Booking/Proposal).
/// Open-ended via `.other` for the full agent set; unknown categories reuse the gold style.
public enum Category: Sendable, Equatable {
    case lead
    case booking
    case proposal
    case other(String)

    public var title: String {
        switch self {
        case .lead: return "Lead"
        case .booking: return "Booking"
        case .proposal: return "Proposal"
        case .other(let name): return name
        }
    }

    /// Testable color seam: the three hex strings a chip is painted with.
    public var palette: (fillHex: String, textHex: String, borderHex: String) {
        switch self {
        case .lead, .other:
            // c-lead: gold fill, --gold-bright text, --line border.
            return ("#d4af3729", Gold.highlightHex, "#d4af3729")
        case .booking:
            // c-book: soft blue.
            return ("#78a0ff21", "#9db8ff", "#78a0ff33")
        case .proposal:
            // c-prop: soft green.
            return ("#78dca01f", "#84d8a4", "#78dca033")
        }
    }
}

/// A small pill chip tagging a message's category (the landing .chip).
public struct CategoryChip: View {
    public let category: Category

    public init(_ category: Category) { self.category = category }

    public var body: some View {
        let p = category.palette
        Text(category.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: p.textHex))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(hex: p.fillHex)))
            .overlay(Capsule().strokeBorder(Color(hex: p.borderHex), lineWidth: 1))
    }
}

#Preview("CategoryChips") {
    HStack(spacing: 10) {
        CategoryChip(.lead)
        CategoryChip(.booking)
        CategoryChip(.proposal)
        CategoryChip(.other("Invoice"))
    }
    .padding(40)
    .background(Color.senaniSurface)
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter CategoryTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: CategoryChip (Lead/Booking/Proposal) with brand palette seam"
```

(Append the standard trailer.)

---

### Task 7: AutonomyDial — Suggest → Draft → Auto segmented control binding SenaniRules.Autonomy

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/AutonomyDial.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/AutonomyOptionTests.swift`

Pins the reconciliation §3 symbol `struct AutonomyDial: View { init(_ binding: Binding<Autonomy>) }`. This is the one component coupled to `SenaniRules`. The pure seam is `enum AutonomyOption` — a `CaseIterable` ordered list (suggest, draft, auto) that maps **bidirectionally** to the frozen `Autonomy` cases (`.ask / .prepare / .auto`) and carries the human-facing label. The dial view is a segmented picker over `AutonomyOption` whose selection round-trips into the bound `Autonomy`. The tests prove: ordering, label text, the `Autonomy ↔ AutonomyOption` mapping is total and lossless, and a `Binding<Autonomy>` round-trips when the selection changes (using a backing variable as the binding's storage — no rendering required).

- [ ] **Step 1: Write failing option + binding round-trip tests**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/AutonomyOptionTests.swift`:

```swift
import Testing
import SwiftUI
import SenaniRules
@testable import SenaniDesign

@Test func optionsAreOrderedSuggestDraftAuto() {
    #expect(AutonomyOption.allCases == [.suggest, .draft, .auto])
}

@Test func labelsMatchTrustLadderWording() {
    #expect(AutonomyOption.suggest.label == "Suggest")
    #expect(AutonomyOption.draft.label == "Draft")
    #expect(AutonomyOption.auto.label == "Auto")
}

@Test func optionMapsToFrozenAutonomyCases() {
    // The load-bearing mapping: display option -> real SenaniRules.Autonomy case.
    #expect(AutonomyOption.suggest.autonomy == .ask)
    #expect(AutonomyOption.draft.autonomy == .prepare)
    #expect(AutonomyOption.auto.autonomy == .auto)
}

@Test func autonomyMapsBackToOptionTotally() {
    #expect(AutonomyOption(autonomy: .ask) == .suggest)
    #expect(AutonomyOption(autonomy: .prepare) == .draft)
    #expect(AutonomyOption(autonomy: .auto) == .auto)
}

@Test func roundTripThroughBothDirectionsIsLossless() {
    for option in AutonomyOption.allCases {
        #expect(AutonomyOption(autonomy: option.autonomy) == option)
    }
    for autonomy in [Autonomy.ask, .prepare, .auto] {
        #expect(AutonomyOption(autonomy: autonomy).autonomy == autonomy)
    }
}

@Test func dialSelectionWritesThroughTheBoundAutonomy() {
    // Drive the dial's selection seam against a real Binding<Autonomy> backed by a var.
    var stored: Autonomy = .ask
    let binding = Binding<Autonomy>(get: { stored }, set: { stored = $0 })

    // The view exposes its selection as a Binding<AutonomyOption> derived from the
    // Autonomy binding; assigning an option must write the mapped case back.
    let selection = AutonomyDial.selectionBinding(for: binding)
    #expect(selection.wrappedValue == .suggest)   // .ask -> .suggest

    selection.wrappedValue = .auto
    #expect(stored == .auto)                       // wrote through

    selection.wrappedValue = .draft
    #expect(stored == .prepare)                    // .draft -> .prepare
}

@Test func dialBuildsWithABinding() {
    var stored: Autonomy = .prepare
    let binding = Binding<Autonomy>(get: { stored }, set: { stored = $0 })
    _ = AutonomyDial(binding).body
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter AutonomyOptionTests
```

Expected: failure — `AutonomyOption` / `AutonomyDial` undefined.

- [ ] **Step 3: Implement `AutonomyOption` + `AutonomyDial`**

Create `Sources/SenaniDesign/AutonomyDial.swift`:

```swift
import SwiftUI
import SenaniRules

/// The display model for the autonomy ladder (ARCHITECTURE.md: Suggest → Draft → Auto).
/// Maps the human-facing labels to the FROZEN SenaniRules.Autonomy cases.
///
/// IMPORTANT: SenaniRules.Autonomy's real cases are `.ask / .prepare / .auto`
/// (the source names `prepare` to avoid colliding with the `draft(...)` action).
/// The dial shows "Suggest / Draft / Auto" over them. This is the single seam
/// coupling SenaniDesign to SenaniRules; if the enum is ever re-frozen, only this maps.
public enum AutonomyOption: CaseIterable, Sendable, Equatable {
    case suggest
    case draft
    case auto

    public var label: String {
        switch self {
        case .suggest: return "Suggest"
        case .draft: return "Draft"
        case .auto: return "Auto"
        }
    }

    /// Display option → frozen Autonomy case.
    public var autonomy: Autonomy {
        switch self {
        case .suggest: return .ask
        case .draft: return .prepare
        case .auto: return .auto
        }
    }

    /// Frozen Autonomy case → display option (total).
    public init(autonomy: Autonomy) {
        switch autonomy {
        case .ask: self = .suggest
        case .prepare: self = .draft
        case .auto: self = .auto
        }
    }
}

/// Per-agent autonomy ladder control (reconciliation §3). A segmented picker
/// over Suggest/Draft/Auto that binds a SenaniRules.Autonomy.
public struct AutonomyDial: View {
    @Binding private var autonomy: Autonomy

    public init(_ autonomy: Binding<Autonomy>) {
        self._autonomy = autonomy
    }

    /// Pure binding adapter (testable without rendering): bridges a Binding<Autonomy>
    /// to a Binding<AutonomyOption> so the Picker can drive it and writes flow back.
    public static func selectionBinding(for autonomy: Binding<Autonomy>) -> Binding<AutonomyOption> {
        Binding<AutonomyOption>(
            get: { AutonomyOption(autonomy: autonomy.wrappedValue) },
            set: { autonomy.wrappedValue = $0.autonomy }
        )
    }

    public var body: some View {
        Picker("Autonomy", selection: AutonomyDial.selectionBinding(for: $autonomy)) {
            ForEach(AutonomyOption.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .tint(Gold.base)
        .font(.senaniBody)
    }
}

#Preview("AutonomyDial") {
    struct DialPreview: View {
        @State var autonomy: Autonomy = .prepare
        var body: some View {
            VStack(spacing: 16) {
                AutonomyDial($autonomy)
                Text("Bound: \(autonomy.rawValue)")
                    .font(.senaniMono).foregroundStyle(Color.senaniMuted)
            }
            .padding(40)
            .background(Color.senaniSurface)
        }
    }
    return DialPreview()
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter AutonomyOptionTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: AutonomyDial (Suggest/Draft/Auto) binding SenaniRules.Autonomy with lossless seam"
```

(Append the standard trailer.)

---

### Task 8: PrimaryButton — the gold-gradient CTA

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/PrimaryButton.swift`
- Test: `Packages/SenaniDesign/Tests/SenaniDesignTests/PrimaryButtonTests.swift`

The landing `.btn-gold`: gold-gradient fill, dark ink text (`#1a1408`), rounded 11px, used for the primary action. The pure seam is `PrimaryButtonStyleSpec` (corner radius, the dark-text hex, horizontal/vertical padding). The view is a `Button` that runs an injected action and renders the gradient via `Gold.gradient`. The test asserts the spec and that the button invokes its action (drive the closure directly — the `action` is a stored property, so calling it proves wiring without a tap).

- [ ] **Step 1: Write a failing spec + action test**

Create `Packages/SenaniDesign/Tests/SenaniDesignTests/PrimaryButtonTests.swift`:

```swift
import Testing
import SwiftUI
@testable import SenaniDesign

@Test func primaryButtonSpecMatchesBrandCTA() {
    let s = PrimaryButtonStyleSpec.default
    #expect(s.cornerRadius == 11)        // .btn border-radius:11px
    #expect(s.textHex == "#1a1408")      // .btn-gold color
    #expect(s.horizontalPadding == 20)
    #expect(s.verticalPadding == 11)
}

@Test func primaryButtonInvokesItsAction() {
    var tapped = 0
    let button = PrimaryButton("Approve") { tapped += 1 }
    button.action()                      // the stored action closure is the wiring seam
    #expect(tapped == 1)
}

@Test func primaryButtonBuilds() {
    _ = PrimaryButton("Star on GitHub") { }.body
}
```

- [ ] **Step 2: Run to fail**

```
cd Packages/SenaniDesign && swift test --filter PrimaryButtonTests
```

Expected: failure — `PrimaryButton` / `PrimaryButtonStyleSpec` undefined.

- [ ] **Step 3: Implement `PrimaryButton`**

Create `Sources/SenaniDesign/PrimaryButton.swift`:

```swift
import SwiftUI

/// Testable spec for the brand's gold CTA (.btn-gold).
public struct PrimaryButtonStyleSpec: Sendable, Equatable {
    public var cornerRadius: CGFloat
    public var textHex: String          // dark ink that reads on gold
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat

    public init(cornerRadius: CGFloat, textHex: String,
                horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        self.cornerRadius = cornerRadius
        self.textHex = textHex
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public static let `default` = PrimaryButtonStyleSpec(
        cornerRadius: 11, textHex: "#1a1408", horizontalPadding: 20, verticalPadding: 11)
}

/// The primary gold-gradient call-to-action (landing .btn-gold).
public struct PrimaryButton: View {
    public let title: String
    public let spec: PrimaryButtonStyleSpec
    public let action: () -> Void

    public init(_ title: String,
                spec: PrimaryButtonStyleSpec = .default,
                action: @escaping () -> Void) {
        self.title = title
        self.spec = spec
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.senaniBody.weight(.semibold))
                .foregroundStyle(Color(hex: spec.textHex))
                .padding(.horizontal, spec.horizontalPadding)
                .padding(.vertical, spec.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: spec.cornerRadius, style: .continuous)
                        .fill(Gold.gradient)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview("PrimaryButton") {
    VStack(spacing: 16) {
        PrimaryButton("Approve & send") { }
        PrimaryButton("★ Star on GitHub") { }
    }
    .padding(40)
    .background(Color.senaniSurface)
}
```

- [ ] **Step 4: Run to pass**

```
cd Packages/SenaniDesign && swift test --filter PrimaryButtonTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: PrimaryButton gold-gradient CTA"
```

(Append the standard trailer.)

---

### Task 9: Component gallery preview + full green run

**Files:**
- Create: `Packages/SenaniDesign/Sources/SenaniDesign/Previews.swift`
- (No new test file — this task runs the whole suite green and adds the aggregate `#Preview`.)

A single gallery `#Preview` lets a developer eyeball every component over the brand surface at once. There is no test seam here (it is purely a preview-time artifact); correctness of each piece is already covered by Tasks 2–8.

- [ ] **Step 1: Add the gallery preview**

Create `Sources/SenaniDesign/Previews.swift`:

```swift
import SwiftUI
import SenaniRules

/// Internal sample host so the gallery #Preview can drive a stateful AutonomyDial.
private struct DesignGallery: View {
    @State private var autonomy: Autonomy = .prepare

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Senani Design System")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            CategoryChip(.lead); CategoryChip(.booking); CategoryChip(.proposal)
                        }
                        Text("Acme Corp — pricing enquiry")
                            .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        Text("Reply drafted in your voice · lead scored 87")
                            .font(.senaniBody).foregroundStyle(Color.senaniMuted)
                    }
                    .padding(20)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Autonomy").font(.senaniBody).foregroundStyle(Color.senaniMuted)
                    AutonomyDial($autonomy)
                }

                PrimaryButton("Approve & send") { }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
    }
}

#Preview("Gallery") {
    DesignGallery()
}
```

- [ ] **Step 2: Run the FULL suite green**

```
cd Packages/SenaniDesign && swift test
```

Expected: ALL tests across every file pass (ColorHex, GoldToken, Token, GlassPanel, Category, AutonomyOption, PrimaryButton).

- [ ] **Step 3: Confirm a clean release build (no warnings as errors surprises)**

```
cd Packages/SenaniDesign && swift build -c release
```

Expected: builds with no errors.

- [ ] **Step 4: Commit**

```
cd Packages/SenaniDesign && git add -A && git commit -m "SenaniDesign: component gallery #Preview + full green suite"
```

(Append the standard trailer.)

---

## Self-Review

Run this checklist before declaring the plan complete.

- **All §3 symbols pinned, names exact.**
  - `enum Gold { static let base/highlight/shadow: Color }` → Task 3 ✔ (plus `gradient`, `gradientStops`).
  - `struct GlassPanel<Content: View>: View` with `init(@ViewBuilder content:)` → Task 5 ✔ (added optional `style:`, default preserves the reconciliation init).
  - `struct AutonomyDial: View` with `init(_ binding: Binding<Autonomy>)` → Task 7 ✔.
  - `extension Font { senaniTitle/senaniBody/senaniMono }` → Task 4 ✔.
  - `extension Color { senaniInk/senaniSurface/senaniAccent }` → Task 4 ✔ (plus `senaniMuted`).
  - Downstream-needed extras: `CategoryChip` → Task 6 ✔, `PrimaryButton` → Task 8 ✔.
- **Cross-package contract honored.** Only upstream dep is `SenaniRules` (`Package.swift`, Task 1). The `Autonomy` case mismatch (`.ask/.prepare/.auto` vs the brief's `suggest/draft/auto`) is explicitly handled by `AutonomyOption` and flagged to the human. No frozen package is edited.
- **Brand fidelity.** Every color hex traces to a `landing/index.html :root` variable (table in Cross-package assumptions); the gold gradient stops/order match `--gold-grad`; `GlassPanel` radii/opacities match `.mock-card`/`.agent`; chip colors match `.c-lead/.c-book/.c-prop`; `PrimaryButton` matches `.btn-gold`. Fonts map brand intent to system fallbacks with a documented bundled-font upgrade path.
- **Testing approach is snapshot-free and deterministic.** No ViewInspector, no snapshot lib. Each view has a pure seam (`HexColor`, `Gold.*Hex`, `SenaniTokens`, `GlassPanelStyle`, `Category.palette`, `AutonomyOption`, `PrimaryButtonStyleSpec`) asserted by exact value; views get a construction/`body`-exercise guard and (for the dial/button) a behavioral seam test (`selectionBinding` round-trip, `action()` invocation). Every component has a `#Preview`.
- **Conventions (reconciliation §4).** macOS 14, Swift 6.2 strict concurrency, Swift Testing (`import Testing`), `swift-tools-version: 6.0`, TDD with failing-test-first + minimal impl + commit per task, complete code with no placeholders.
- **Scope discipline.** No composition root, no screens, no animation, no theme switching, no font bundling — all explicitly deferred. The package builds and tests in isolation with `swift test` and `swift build -c release`.
- **Did I add anything not asked for?** `senaniMmuted`, `Gold.gradient/gradientStops`, `GlassPanelStyle.compact`, `Category.other` — each justified by a concrete downstream need (chip/button text, the CTA fill, the agent-card variant, the 10-agent open category set). No speculative API beyond that.
