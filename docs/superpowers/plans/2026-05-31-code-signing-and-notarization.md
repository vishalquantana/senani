# Code Signing & Notarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This is an INFRA / PACKAGING plan — there are NO Swift unit tests.** "Verification" means running the exact `codesign` / `spctl` / `xcrun notarytool` / `stapler` commands shown and confirming the EXACT expected output. Treat a missing/mismatched expected line as a failing test: stop and fix before the next task.

**Goal:** Take the existing `SenaniApp` SwiftPM **executable** (built by `docs/superpowers/plans/2026-05-31-app-shell-and-composition-root.md`) and turn it into a distributable, Gatekeeper-passing macOS application: assemble a proper `.app` bundle (layout + `Info.plist` + icon from `assets/`), sign it with a **Developer ID Application** certificate under the **hardened runtime** with a **secure timestamp** and the **minimal entitlements** the app actually uses (outbound HTTPS to Google, read/write of its own Application Support files, Keychain), **notarize** it with `xcrun notarytool submit --wait` using an **App Store Connect API key**, **staple** the ticket, and **verify** with `codesign --verify --deep --strict`, `spctl -a -t exec`, and `xcrun stapler validate` — all driven by one reproducible `Scripts/package_and_sign.sh` plus a GitHub Actions release job that runs it on a `v*` tag with all secrets injected from CI secrets (never committed). This is the Roadmap **Deferred — "Code signing + notarization"** item.

**Architecture:** The app ships as a **SwiftPM executable**, not an Xcode app target. The reconciliation doc (`2026-05-31-APP-PLANS-RECONCILIATION.md` §1) and the app-shell plan both pin the app as the `SenaniApp/` executable that builds, runs, and tests headlessly with `swift build` / `swift run` / `swift test`. We therefore choose the **minimal, reproducible path: a packaging script that assembles a `.app` bundle around the `swift build -c release` binary** — we do NOT migrate to an `.xcodeproj`. (Justification in "Why a packaging script, not an Xcode target" below.) The pipeline is strictly ordered: **build → assemble bundle → sign (inside-out: helpers first, then the outer `.app`) → notarize the zipped bundle → staple the `.app` → verify → (optionally) wrap in a `.dmg`, sign + notarize + staple the `.dmg` too**. Every secret (Developer ID identity, Team ID, App Store Connect issuer/key-id/`.p8`) is a clearly-flagged **HUMAN-SUPPLIED INPUT** read from the environment — never hard-coded, never committed (`.gitignore` already blocks `*.p8`, `*.p12`, `client_secret*.json`, `.env`).

**Tech Stack:** macOS 14+ (Apple Silicon, `arm64`), Swift 6 / SwiftPM (`swift build -c release`), Apple `codesign`, `xcrun notarytool` (the modern notarization tool; **do NOT use the retired `altool`**), `xcrun stapler`, `spctl`, `/usr/libexec/PlistBuddy`, `iconutil`, `sips`, `ditto`, `hdiutil`. Apple Developer Program membership and a **Developer ID Application** certificate are prerequisites (human-supplied). CI: GitHub Actions on `macos-14` runners (already present at `.github/workflows/release.yml`).

**Working directory:** All `swift` and packaging commands run from the **repo root** (`/Users/vishalkumar/Downloads/qmail`), because the `.app` is assembled from the repo-root `SenaniApp/` build output and the icon from repo-root `assets/`. Paths in the script are relative to the script's own location so it is invocable from anywhere.

**Identifiers (pinned, matching the codebase):** Bundle identifier family is **`in.quantana.senani`** (the Keychain service is already `in.quantana.senani.gmail` in `Packages/SenaniGmail/Sources/SenaniGmail/Keychain.swift`). The app bundle id is **`in.quantana.senani`**; product/executable name **`Senani`** (user-facing) wrapping the SwiftPM product **`SenaniApp`**.

---

## HUMAN-SUPPLIED INPUTS (flagged — never hard-code, never commit)

These five values come from the human's Apple Developer account. The script reads each from an environment variable; CI injects them from repository **Secrets**. **None is ever written to a tracked file.**

| Input | Env var | Where it comes from | Example shape (NOT a real value) |
|-------|---------|---------------------|----------------------------------|
| Developer ID Application identity | `SENANI_SIGN_IDENTITY` | The signing cert's common name, as shown by `security find-identity -v -p codesigning` | `Developer ID Application: Quantana (TEAMID1234)` |
| Apple Team ID | `SENANI_TEAM_ID` | Apple Developer → Membership | `TEAMID1234` (10 chars) |
| App Store Connect API **Issuer ID** | `SENANI_ASC_ISSUER_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API | `69a6de7e-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (UUID) |
| App Store Connect API **Key ID** | `SENANI_ASC_KEY_ID` | Same page; shown next to the key | `ABCDE12345` (10 chars) |
| App Store Connect API **private key** (`.p8`) | `SENANI_ASC_KEY_PATH` | Downloaded once as `AuthKey_<KEYID>.p8` (cannot be re-downloaded) | path to a `.p8` file on disk / in the CI runner |

> **The signing certificate itself** (`Developer ID Application`) plus its private key must be present in a **Keychain** at sign time. Locally that is your login keychain. In CI it is imported from a base64 `.p12` secret into a temporary keychain (Task 7). The API key (`.p8`) is ONLY for notarization, not for signing — two different credentials.

---

## Why a packaging script, not an Xcode app target (decision + justification)

Recorded so the deferred-phase worker does not relitigate it:

- **The app IS a SwiftPM executable, and that is locked.** `2026-05-31-APP-PLANS-RECONCILIATION.md` §1 and the app-shell plan both pin `SenaniApp/` as a `.executableTarget` whose definition of done is `swift build` / `swift run` / `swift test`. Migrating to an `.xcodeproj` would fork the build the rest of the ~20 app plans target. The app-shell plan explicitly anticipates this: *"When [packaging] lands, a thin generated xcodeproj (or `swift build` + a packaging script) wraps this same `SenaniApp` target — the composition root and views are unchanged."* We take the `swift build` + script branch — the smaller, reversible change.
- **A `.app` is just a directory tree.** `codesign` / `notarytool` / `stapler` operate on a bundle, not on an Xcode scheme. `swift build -c release` already produces a Mach-O `arm64` executable; wrapping it in `Senani.app/Contents/{MacOS,Resources}` + an `Info.plist` is mechanical and fully scriptable. No Xcode project, scheme, or `xcodebuild archive` needed.
- **Reproducible & CI-friendly.** The same `Scripts/package_and_sign.sh` runs identically on a developer's Mac and on a `macos-14` GitHub runner. No GUI, no scheme drift.
- **The cost we accept:** SwiftPM does not give us an automatic `Info.plist`, an asset-catalog `.icns`, or an entitlements file — we author all three by hand (Tasks 2–4). That is a one-time, ~120-line cost and is the entire point of this plan.
- **App Sandbox is intentionally NOT enabled.** Developer ID (direct distribution, outside the Mac App Store) does **not require** the sandbox, and the app reads/writes `~/Library/Application Support/Senani` and loads MLX model weights from arbitrary user-chosen locations — both awkward under the sandbox. Gatekeeper/notarization require the **hardened runtime**, which we DO enable. (If a future Mac App Store build is wanted, that is a separate plan adding the sandbox + its entitlements.)

---

## Entitlements rationale (minimal — NO telemetry)

The architecture (`docs/ARCHITECTURE.md`) is explicit: **on-device, no telemetry, no accounts; the ONLY network hop is the user's own Google account.** The hardened runtime denies things by default; we add back ONLY what the app provably needs:

| Entitlement | Value | Why it is needed | Why it is safe |
|-------------|-------|------------------|----------------|
| `com.apple.security.cs.allow-jit` | `true` | **MLX / Metal** inference (`MLXTextGenerator`) JIT-compiles Metal kernels at runtime on Apple Silicon. Without this the hardened runtime kills JIT pages. | Standard for any Metal-compute / ML app. |
| `com.apple.security.network.client` | `true` | Outbound HTTPS to Gmail + Google Calendar APIs and Hugging Face model downloads (`URLSessionHTTPClient`). | Client-only; the app runs **no server** and opens **no listening socket**. (No `network.server`.) |
| (Keychain access) | — implicit — | OAuth tokens live in the macOS Keychain (`KeychainTokenStore`, service `in.quantana.senani.gmail`). | **No entitlement key is required** for a Developer-ID (non-sandboxed) app to use its own generic-password Keychain items. The hardened runtime does not block Keychain. We rely on a stable signing identity so Keychain ACLs persist across launches — which is exactly what a consistent Developer ID signature provides. |
| (Own-file read/write) | — implicit — | SQLite store + model cache under `~/Library/Application Support/Senani`. | **No entitlement required** without the sandbox; a hardened, non-sandboxed app has normal user-level filesystem access. |

**Deliberately ABSENT (and why):**
- `com.apple.security.app-sandbox` — not using the sandbox (see decision above).
- `com.apple.security.cs.allow-unsigned-executable-memory` / `…disable-library-validation` — **not added**. MLX needs `allow-jit` only; unsigned-executable-memory is broader and unnecessary. If, and only if, MLX runtime loading later fails at launch with a library-validation crash for a legitimately-signed dependency, revisit `disable-library-validation` — do not add it pre-emptively.
- Any analytics / crash-reporting / network-server entitlement — there is **no telemetry**, by design.

---

## File Structure

```
Scripts/
  package_and_sign.sh        # CREATE: the one reproducible pipeline (build → bundle → sign → notarize → staple → verify → dmg)
  Senani.entitlements        # CREATE: hardened-runtime entitlements plist (allow-jit + network.client only)
  Info.plist.template        # CREATE: Info.plist with @@VERSION@@/@@BUILD@@ tokens the script substitutes
  make_icon.sh               # CREATE: builds Senani.icns from assets/senani-logo.svg (or a PNG) via iconutil
.github/workflows/
  release.yml                # MODIFY: replace the stubbed build step with a job that runs package_and_sign.sh on v* tags, secrets injected
docs/
  SIGNING.md                 # CREATE: human-facing runbook — how to obtain each secret, set CI secrets, run locally, rotate keys
```

> Nothing under `Scripts/` contains a secret. The entitlements plist, Info.plist template, and icon script are safe to commit. `.gitignore` already blocks `*.p8`, `*.p12`, `*.xcconfig.local`, `secrets.plist`, `.env*`, `client_secret*.json` — confirm in Task 1.

---

### Task 1: Confirm prerequisites & secret hygiene (no code yet)

**Files:** none (verification only).

- [ ] **Step 1: Confirm the SwiftPM app builds in release.**

```
swift build -c release --package-path SenaniApp --product SenaniApp
```

Expected: `Build complete!` and a binary at `SenaniApp/.build/release/SenaniApp`. Confirm it is an `arm64` Mach-O:

```
file SenaniApp/.build/release/SenaniApp
```

Expected output contains: `Mach-O 64-bit executable arm64`.

> If the build fails because `SenaniEngine`/the app-shell plan has not landed yet, STOP — this plan has a hard build-order dependency on the app-shell plan (reconciliation §1: app shell precedes Deferred packaging). Do not stub anything.

- [ ] **Step 2: Confirm a signing identity is available (local dev).**

```
security find-identity -v -p codesigning
```

Expected: at least one line of the form `1) <40-hex-SHA1> "Developer ID Application: <Name> (<TEAMID>)"` and a trailing `N valid identities found`. **If zero Developer ID Application identities appear, the human must install the cert + private key first** (Apple Developer → Certificates → Developer ID Application; double-click the downloaded `.cer`, ensure the private key is in the login keychain). Record the exact identity string — it becomes `SENANI_SIGN_IDENTITY`.

- [ ] **Step 3: Confirm secrets are git-ignored.**

```
git check-ignore -v .env client_secret_senani.apps.googleusercontent.com.json
```

Expected: each path prints with the matching `.gitignore` rule (e.g. `.gitignore:NN:.env	.env`). Also confirm `*.p8` and `*.p12` are ignored:

```
git check-ignore -v dummy.p8 dummy.p12
```

Expected: both match (`*.p8`, `*.p12` rules). **Do not create real `.p8`/`.p12` files in the repo tree** — keep them outside the working copy or only in `~/.senani-secrets/`.

- [ ] **Step 4: Commit (marker commit, branch first if on default).**

```
git switch -c signing-notarization 2>/dev/null || git switch signing-notarization
git commit --allow-empty -m "chore(signing): begin code-signing & notarization track

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> Use this trailer on EVERY commit in this plan.

---

### Task 2: Hardened-runtime entitlements plist

**Files:** Create `Scripts/Senani.entitlements`.

- [ ] **Step 1: Write the entitlements file.**

Create `Scripts/Senani.entitlements` EXACTLY:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- MLX/Metal JIT-compiles compute kernels at runtime. Required under the
         hardened runtime; without it the JIT pages are killed. -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>

    <!-- Outbound HTTPS to Gmail + Google Calendar APIs and Hugging Face model
         downloads. Client only; the app runs no server. -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- INTENTIONALLY ABSENT: app-sandbox (Developer ID, not MAS),
         network.server (no listening socket), allow-unsigned-executable-memory
         and disable-library-validation (allow-jit suffices for MLX), and any
         telemetry/analytics entitlement (there is none, by design). -->
</dict>
</plist>
```

- [ ] **Step 2: Validate it parses as a plist.**

```
plutil -lint Scripts/Senani.entitlements
```

Expected: `Scripts/Senani.entitlements: OK`.

- [ ] **Step 3: Commit.**

```
git add Scripts/Senani.entitlements
git commit -m "signing: hardened-runtime entitlements (allow-jit + network.client only, no telemetry)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Info.plist template

**Files:** Create `Scripts/Info.plist.template`.

The `.app` needs an `Info.plist` declaring the bundle id, version, executable name, minimum OS, and that it is an Apple-Silicon app. `@@VERSION@@` / `@@BUILD@@` are substituted by the script from the git tag.

- [ ] **Step 1: Write the template.**

Create `Scripts/Info.plist.template` EXACTLY:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Senani</string>
    <key>CFBundleDisplayName</key>
    <string>Senani</string>
    <key>CFBundleIdentifier</key>
    <string>in.quantana.senani</string>
    <key>CFBundleVersion</key>
    <string>@@BUILD@@</string>
    <key>CFBundleShortVersionString</key>
    <string>@@VERSION@@</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Senani</string>
    <key>CFBundleIconFile</key>
    <string>Senani</string>
    <key>CFBundleIconName</key>
    <string>Senani</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>© Quantana. All rights reserved.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
</dict>
</plist>
```

> `CFBundleExecutable` is `Senani` (the script copies the SwiftPM `SenaniApp` binary to `Contents/MacOS/Senani`). `CFBundleVersion` must be a monotonically increasing build number; `CFBundleShortVersionString` is the human version (`1.2.3`). NO `NSAppTransportSecurity` exception is added — all Google/HF endpoints are HTTPS, so default ATS is satisfied.

- [ ] **Step 2: Lint a token-substituted copy** (prove the template is valid plist once filled):

```
sed -e 's/@@VERSION@@/0.0.0/' -e 's/@@BUILD@@/1/' Scripts/Info.plist.template > /tmp/Info.test.plist
plutil -lint /tmp/Info.test.plist
```

Expected: `/tmp/Info.test.plist: OK`.

- [ ] **Step 3: Commit.**

```
git add Scripts/Info.plist.template
git commit -m "signing: Info.plist template (bundle id in.quantana.senani, arm64, macOS 14+)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Icon builder (assets/ → Senani.icns)

**Files:** Create `Scripts/make_icon.sh`.

`assets/senani-logo.svg` is the brand mark. macOS bundles want a `.icns`. `iconutil` consumes a PNG-filled `.iconset`; `sips` can't read SVG, so we rasterize the SVG to a large PNG first (preferring `rsvg-convert` if present, else a `qlmanage`/`sips` fallback from any committed PNG). The result is `Scripts/Senani.icns` (git-ignored build artifact).

- [ ] **Step 1: Write the icon script.**

Create `Scripts/make_icon.sh` EXACTLY:

```bash
#!/usr/bin/env bash
# Builds Scripts/Senani.icns from a source image.
# Prefers assets/senani-logo.svg (rasterized via rsvg-convert); falls back to
# assets/senani-icon-1024.png if that PNG is committed. Produces a 1024px master
# then iconutil-packs all required sizes. Idempotent; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSETS="${REPO_ROOT}/assets"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

MASTER="${WORK}/master-1024.png"

if command -v rsvg-convert >/dev/null 2>&1 && [[ -f "${ASSETS}/senani-logo.svg" ]]; then
    echo "Rasterizing assets/senani-logo.svg at 1024x1024 via rsvg-convert"
    rsvg-convert -w 1024 -h 1024 "${ASSETS}/senani-logo.svg" -o "${MASTER}"
elif [[ -f "${ASSETS}/senani-icon-1024.png" ]]; then
    echo "Using committed assets/senani-icon-1024.png as the master"
    sips -z 1024 1024 "${ASSETS}/senani-icon-1024.png" --out "${MASTER}" >/dev/null
else
    echo "ERROR: need either rsvg-convert + assets/senani-logo.svg, or assets/senani-icon-1024.png" >&2
    echo "Install rsvg: brew install librsvg   (or commit a 1024px PNG icon)" >&2
    exit 1
fi

ICONSET="${WORK}/Senani.iconset"
mkdir -p "${ICONSET}"
# Apple-required iconset members: 16/32/128/256/512 at @1x and @2x.
for spec in \
    "16 icon_16x16" "32 icon_16x16@2x" \
    "32 icon_32x32" "64 icon_32x32@2x" \
    "128 icon_128x128" "256 icon_128x128@2x" \
    "256 icon_256x256" "512 icon_256x256@2x" \
    "512 icon_512x512" "1024 icon_512x512@2x"; do
    px="${spec%% *}"; name="${spec##* }"
    sips -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}.png" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "${SCRIPT_DIR}/Senani.icns"
echo "Wrote ${SCRIPT_DIR}/Senani.icns"
```

- [ ] **Step 2: Make executable and run.**

```
chmod +x Scripts/make_icon.sh
Scripts/make_icon.sh
```

Expected (with `librsvg` installed): `Rasterizing assets/senani-logo.svg …` then `Wrote …/Scripts/Senani.icns`. Verify the icns:

```
file Scripts/Senani.icns
```

Expected: `Scripts/Senani.icns: Mac OS X icon`.

> If `rsvg-convert` is absent and no PNG master is committed, the script exits with the install hint. On CI we `brew install librsvg` (Task 8). The SVG (`assets/senani-logo.svg`) is a 100×100 viewBox vector that scales cleanly to 1024.

- [ ] **Step 3: Git-ignore the generated icns and commit the script.**

Add to `.gitignore` (under a new "Build artifacts" comment):

```
# Generated signing/packaging artifacts
Scripts/Senani.icns
dist/
```

Then:

```
git add Scripts/make_icon.sh .gitignore
git commit -m "signing: icon builder (assets/senani-logo.svg -> Senani.icns) + ignore artifacts

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: The packaging + signing pipeline script

**Files:** Create `Scripts/package_and_sign.sh`.

This is the heart of the plan: one script, run as `Scripts/package_and_sign.sh <version>`, that builds, assembles the bundle, signs inside-out, notarizes, staples, verifies, and (optionally) produces a signed+notarized `.dmg`. It reads every secret from the environment; it hard-codes NOTHING secret.

- [ ] **Step 1: Write the script.**

Create `Scripts/package_and_sign.sh` EXACTLY:

```bash
#!/usr/bin/env bash
# Senani — package, sign, notarize, staple, verify.
#
# Usage:  Scripts/package_and_sign.sh <version> [build-number]
#   e.g.  Scripts/package_and_sign.sh 0.1.0 1
#
# REQUIRED environment (HUMAN-SUPPLIED — never hard-coded, never committed):
#   SENANI_SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"
#   SENANI_TEAM_ID         10-char Apple Team ID
#   SENANI_ASC_ISSUER_ID   App Store Connect API issuer UUID
#   SENANI_ASC_KEY_ID      App Store Connect API key id
#   SENANI_ASC_KEY_PATH    path to AuthKey_<KEYID>.p8
# OPTIONAL:
#   SENANI_KEYCHAIN        keychain to search for the signing identity (CI temp keychain)
#   SENANI_MAKE_DMG=1      also build a signed+notarized .dmg
set -euo pipefail

# ---- args ----
VERSION="${1:?usage: package_and_sign.sh <version> [build-number]}"
BUILD_NUMBER="${2:-$(date +%Y%m%d%H%M)}"

# ---- locate paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PKG="${REPO_ROOT}/SenaniApp"
DIST="${REPO_ROOT}/dist"
APP="${DIST}/Senani.app"
PRODUCT_BIN="${APP_PKG}/.build/release/SenaniApp"

# ---- required secrets (fail fast with a clear message) ----
: "${SENANI_SIGN_IDENTITY:?set SENANI_SIGN_IDENTITY (Developer ID Application: ...)}"
: "${SENANI_TEAM_ID:?set SENANI_TEAM_ID}"
: "${SENANI_ASC_ISSUER_ID:?set SENANI_ASC_ISSUER_ID}"
: "${SENANI_ASC_KEY_ID:?set SENANI_ASC_KEY_ID}"
: "${SENANI_ASC_KEY_PATH:?set SENANI_ASC_KEY_PATH (path to AuthKey_*.p8)}"

KEYCHAIN_ARG=()
if [[ -n "${SENANI_KEYCHAIN:-}" ]]; then
    KEYCHAIN_ARG=(--keychain "${SENANI_KEYCHAIN}")
fi

echo "==> Senani ${VERSION} (build ${BUILD_NUMBER})"

# ---- 1. build the release binary ----
echo "==> swift build -c release"
swift build -c release --package-path "${APP_PKG}" --product SenaniApp
test -f "${PRODUCT_BIN}" || { echo "missing ${PRODUCT_BIN}" >&2; exit 1; }

# ---- 2. assemble the .app bundle ----
echo "==> assembling Senani.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

# executable
cp "${PRODUCT_BIN}" "${APP}/Contents/MacOS/Senani"
chmod +x "${APP}/Contents/MacOS/Senani"

# icon
"${SCRIPT_DIR}/make_icon.sh"
cp "${SCRIPT_DIR}/Senani.icns" "${APP}/Contents/Resources/Senani.icns"

# Info.plist (substitute version tokens)
sed -e "s/@@VERSION@@/${VERSION}/g" -e "s/@@BUILD@@/${BUILD_NUMBER}/g" \
    "${SCRIPT_DIR}/Info.plist.template" > "${APP}/Contents/Info.plist"
plutil -lint "${APP}/Contents/Info.plist"

# PkgInfo (classic, harmless)
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# ---- 3. sign INSIDE-OUT (helpers/dylibs first, the .app last) ----
ENTITLEMENTS="${SCRIPT_DIR}/Senani.entitlements"
SIGN_FLAGS=(--force --options runtime --timestamp \
            --sign "${SENANI_SIGN_IDENTITY}" "${KEYCHAIN_ARG[@]}")

echo "==> signing nested Mach-O (frameworks/dylibs/bundles) first"
# Sign every nested signable item deepest-first. swift build may vendor MLX
# dylibs/resources; sign each so --deep verification passes.
while IFS= read -r -d '' f; do
    echo "    sign: ${f#${APP}/}"
    codesign "${SIGN_FLAGS[@]}" "${f}"
done < <(find "${APP}/Contents" \
            \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' \) \
            -print0 | sort -rz)

echo "==> signing the main executable"
codesign "${SIGN_FLAGS[@]}" "${APP}/Contents/MacOS/Senani"

echo "==> signing the outer Senani.app (with entitlements)"
codesign "${SIGN_FLAGS[@]}" --entitlements "${ENTITLEMENTS}" "${APP}"

# ---- 4. pre-notarization local verification ----
echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "${APP}"

echo "==> display signing info"
codesign -dvvv "${APP}" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|flags|Timestamp' || true

# ---- 5. notarize (zip -> submit --wait -> staple) ----
ZIP="${DIST}/Senani-${VERSION}.zip"
echo "==> ditto zip for notarization"
/usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "==> xcrun notarytool submit --wait"
xcrun notarytool submit "${ZIP}" \
    --issuer "${SENANI_ASC_ISSUER_ID}" \
    --key-id "${SENANI_ASC_KEY_ID}" \
    --key "${SENANI_ASC_KEY_PATH}" \
    --wait

echo "==> xcrun stapler staple Senani.app"
xcrun stapler staple "${APP}"

# ---- 6. final verification (Gatekeeper accepts) ----
echo "==> xcrun stapler validate"
xcrun stapler validate "${APP}"

echo "==> spctl assessment (execution policy)"
spctl -a -vvv -t exec "${APP}"

echo "==> re-verify signature post-staple"
codesign --verify --deep --strict --verbose=2 "${APP}"

# ---- 7. optional: signed + notarized .dmg ----
if [[ "${SENANI_MAKE_DMG:-0}" == "1" ]]; then
    DMG="${DIST}/Senani-${VERSION}.dmg"
    STAGING="$(mktemp -d)"
    cp -R "${APP}" "${STAGING}/Senani.app"
    ln -s /Applications "${STAGING}/Applications"
    echo "==> hdiutil create dmg"
    rm -f "${DMG}"
    hdiutil create -volname "Senani ${VERSION}" -srcfolder "${STAGING}" \
        -ov -format UDZO "${DMG}"
    rm -rf "${STAGING}"

    echo "==> sign the dmg"
    codesign --force --timestamp --sign "${SENANI_SIGN_IDENTITY}" "${KEYCHAIN_ARG[@]}" "${DMG}"

    echo "==> notarize the dmg"
    xcrun notarytool submit "${DMG}" \
        --issuer "${SENANI_ASC_ISSUER_ID}" \
        --key-id "${SENANI_ASC_KEY_ID}" \
        --key "${SENANI_ASC_KEY_PATH}" \
        --wait

    echo "==> staple + verify the dmg"
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
    spctl -a -vvv -t install "${DMG}"
    echo "==> built ${DMG}"
fi

echo "==> DONE. Artifacts in ${DIST}"
```

- [ ] **Step 2: Shellcheck + syntax check (no secrets needed).**

```
chmod +x Scripts/package_and_sign.sh
bash -n Scripts/package_and_sign.sh
command -v shellcheck >/dev/null 2>&1 && shellcheck Scripts/package_and_sign.sh || echo "shellcheck not installed; bash -n passed"
```

Expected: `bash -n` prints nothing (syntax OK). If `shellcheck` is present, expect no errors (warnings about `KEYCHAIN_ARG` array expansion under `set -u` are acceptable — the code guards with `[[ -n ... ]]`).

- [ ] **Step 3: Confirm it fails CLEANLY with no secrets** (the fail-fast guard, run WITHOUT exporting any secret):

```
env -u SENANI_SIGN_IDENTITY -u SENANI_TEAM_ID -u SENANI_ASC_ISSUER_ID \
    -u SENANI_ASC_KEY_ID -u SENANI_ASC_KEY_PATH \
    Scripts/package_and_sign.sh 0.0.0 1; echo "exit=$?"
```

Expected: it prints `set SENANI_SIGN_IDENTITY (Developer ID Application: ...)` to stderr and exits non-zero (the `: "${VAR:?msg}"` guard). This proves no secret is baked in.

- [ ] **Step 4: Commit.**

```
git add Scripts/package_and_sign.sh
git commit -m "signing: package_and_sign.sh (build -> bundle -> sign -> notarize --wait -> staple -> verify)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Local end-to-end dry run (human-gated — requires real credentials)

**Files:** none (execution + verification only). **This task REQUIRES the human's real Developer ID identity and App Store Connect API key.** It cannot run in a credential-less worktree; flag it for the human and run it on their Mac.

- [ ] **Step 1: Export the secrets (in the human's shell — NOT committed).**

```
export SENANI_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export SENANI_TEAM_ID="<TEAMID>"
export SENANI_ASC_ISSUER_ID="<issuer-uuid>"
export SENANI_ASC_KEY_ID="<key-id>"
export SENANI_ASC_KEY_PATH="$HOME/.senani-secrets/AuthKey_<KEYID>.p8"
```

- [ ] **Step 2: Run the full pipeline (incl. dmg).**

```
SENANI_MAKE_DMG=1 Scripts/package_and_sign.sh 0.1.0 1
```

- [ ] **Step 3: Confirm EACH expected verification line.**

`codesign --verify --deep --strict --verbose=2 dist/Senani.app` must print:

```
dist/Senani.app: valid on disk
dist/Senani.app: satisfies its Designated Requirement
```

`codesign -dvvv dist/Senani.app` must show (among others):

```
Identifier=in.quantana.senani
Authority=Developer ID Application: <Name> (<TEAMID>)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=<TEAMID>
Timestamp=<a real date>     # secure timestamp present
```
and the `flags` line includes `runtime` (hardened runtime on).

`xcrun notarytool submit --wait` must end with:

```
status: Accepted
```
(If it prints `Invalid`, fetch the log: `xcrun notarytool log <submission-id> --issuer ... --key-id ... --key ...` and fix the flagged issue — almost always a missing `--options runtime`/`--timestamp` on a nested binary.)

`xcrun stapler staple dist/Senani.app` must print:

```
The staple and validate action worked!
```

`xcrun stapler validate dist/Senani.app` must print:

```
The validate action worked!
```

`spctl -a -vvv -t exec dist/Senani.app` must print:

```
dist/Senani.app: accepted
source=Notarized Developer ID
```

For the dmg, `spctl -a -vvv -t install dist/Senani-0.1.0.dmg` must print:

```
dist/Senani-0.1.0.dmg: accepted
source=Notarized Developer ID
```

- [ ] **Step 4: Fresh-machine simulation (Gatekeeper quarantine).** Prove a downloaded copy launches without the "unidentified developer" block:

```
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/Senani.app
spctl -a -vvv -t exec dist/Senani.app
```

Expected: still `accepted / source=Notarized Developer ID` even with the quarantine bit set — that is the whole point of notarization+stapling.

- [ ] **Step 5: No commit** (this task produces only ignored `dist/` artifacts). Record the verified output in the PR description.

---

### Task 7: CI keychain import helper (for the GitHub Actions runner)

**Files:** the import logic lives INLINE in `release.yml` (Task 8); this task documents and pins the exact commands so they are reviewable. **No file beyond the workflow.**

The runner has no login keychain with the cert. We import the Developer ID cert+key from a base64-encoded `.p12` secret into a throwaway keychain, set it searchable, and pass that keychain to `codesign`.

- [ ] **Step 1: Pin the import sequence (used verbatim in Task 8).**

```bash
KEYCHAIN="$RUNNER_TEMP/senani-signing.keychain-db"
KEYCHAIN_PW="$(openssl rand -base64 24)"

# create + unlock a temporary keychain
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"

# import the Developer ID cert + private key from the base64 .p12 secret
echo "$SENANI_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" \
    -P "$SENANI_CERT_P12_PASSWORD" -T /usr/bin/codesign
rm -f "$RUNNER_TEMP/cert.p12"

# allow codesign to use the key without an interactive prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null

# put the temp keychain in the search list so the identity resolves
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
```

> The script then runs with `SENANI_KEYCHAIN="$KEYCHAIN"` so `codesign` uses it. Two NEW CI-only secrets are required here (in addition to the five in the inputs table): `SENANI_CERT_P12_BASE64` (the Developer ID Application cert+key exported as `.p12`, then `base64 -i cert.p12 | pbcopy`) and `SENANI_CERT_P12_PASSWORD`. The App Store Connect `.p8` is written from the `SENANI_ASC_KEY_BASE64` secret to a temp file at runtime.

- [ ] **Step 2: No commit** (documentation; the commands land in `release.yml` next).

---

### Task 8: GitHub Actions release job

**Files:** Modify `.github/workflows/release.yml`.

Replace the stubbed build step with a real job that, on a `v*` tag, runs the full pipeline with secrets injected from CI secrets and uploads the signed+notarized artifacts to the GitHub Release.

- [ ] **Step 1: Replace `release.yml` entirely.**

Write `.github/workflows/release.yml` EXACTLY:

```yaml
name: Release

# Builds, signs, notarizes, staples, and publishes the macOS app on a v* tag.
# All credentials come from repository Secrets — none is committed.
#
# Required repository Secrets:
#   SENANI_SIGN_IDENTITY     "Developer ID Application: <Name> (<TEAMID>)"
#   SENANI_TEAM_ID           Apple Team ID
#   SENANI_CERT_P12_BASE64   base64 of the Developer ID Application cert+key .p12
#   SENANI_CERT_P12_PASSWORD password used when exporting that .p12
#   SENANI_ASC_ISSUER_ID     App Store Connect API issuer UUID
#   SENANI_ASC_KEY_ID        App Store Connect API key id
#   SENANI_ASC_KEY_BASE64    base64 of the AuthKey_<KEYID>.p8

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

      - name: Select Xcode (toolchain for swift + notarytool)
        run: sudo xcode-select -s /Applications/Xcode_16.app

      - name: Install librsvg (icon rasterization)
        run: brew install librsvg

      - name: Derive version from tag
        id: ver
        run: |
          TAG="${GITHUB_REF_NAME#v}"
          echo "version=${TAG}" >> "$GITHUB_OUTPUT"
          echo "build=${GITHUB_RUN_NUMBER}" >> "$GITHUB_OUTPUT"

      - name: Import signing certificate into a temporary keychain
        env:
          SENANI_CERT_P12_BASE64: ${{ secrets.SENANI_CERT_P12_BASE64 }}
          SENANI_CERT_P12_PASSWORD: ${{ secrets.SENANI_CERT_P12_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN="$RUNNER_TEMP/senani-signing.keychain-db"
          KEYCHAIN_PW="$(openssl rand -base64 24)"
          security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
          echo "$SENANI_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" \
            -P "$SENANI_CERT_P12_PASSWORD" -T /usr/bin/codesign
          rm -f "$RUNNER_TEMP/cert.p12"
          security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
          security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
          echo "SENANI_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"

      - name: Write App Store Connect API key to a temp file
        env:
          SENANI_ASC_KEY_BASE64: ${{ secrets.SENANI_ASC_KEY_BASE64 }}
        run: |
          set -euo pipefail
          KEY_PATH="$RUNNER_TEMP/AuthKey.p8"
          echo "$SENANI_ASC_KEY_BASE64" | base64 --decode > "$KEY_PATH"
          echo "SENANI_ASC_KEY_PATH=$KEY_PATH" >> "$GITHUB_ENV"

      - name: Package, sign, notarize, staple
        env:
          SENANI_SIGN_IDENTITY: ${{ secrets.SENANI_SIGN_IDENTITY }}
          SENANI_TEAM_ID: ${{ secrets.SENANI_TEAM_ID }}
          SENANI_ASC_ISSUER_ID: ${{ secrets.SENANI_ASC_ISSUER_ID }}
          SENANI_ASC_KEY_ID: ${{ secrets.SENANI_ASC_KEY_ID }}
          SENANI_MAKE_DMG: "1"
        run: |
          Scripts/package_and_sign.sh "${{ steps.ver.outputs.version }}" "${{ steps.ver.outputs.build }}"

      - name: Clean up secrets from the runner
        if: always()
        run: |
          rm -f "$RUNNER_TEMP/AuthKey.p8" || true
          security delete-keychain "$RUNNER_TEMP/senani-signing.keychain-db" || true

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
          prerelease: ${{ contains(github.ref_name, '-') }}
          files: |
            dist/Senani-*.dmg
            dist/Senani-*.zip
```

- [ ] **Step 2: Validate the workflow YAML.**

```
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```

Expected: `YAML OK`. If `actionlint` is available, also run `actionlint .github/workflows/release.yml` (expect no errors).

- [ ] **Step 3: Document the seven required Secrets** so the human sets them in GitHub → Settings → Secrets and variables → Actions (also covered in `docs/SIGNING.md`, Task 9):

| Secret | How to produce |
|--------|----------------|
| `SENANI_SIGN_IDENTITY` | the exact CN from `security find-identity -v -p codesigning` |
| `SENANI_TEAM_ID` | Apple Developer → Membership |
| `SENANI_CERT_P12_BASE64` | export the Developer ID Application cert+key from Keychain Access as `cert.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `SENANI_CERT_P12_PASSWORD` | the password chosen during that `.p12` export |
| `SENANI_ASC_ISSUER_ID` | App Store Connect → Integrations → App Store Connect API |
| `SENANI_ASC_KEY_ID` | same page, next to the key |
| `SENANI_ASC_KEY_BASE64` | `base64 -i AuthKey_<KEYID>.p8 \| pbcopy` |

- [ ] **Step 4: Commit.**

```
git add .github/workflows/release.yml
git commit -m "ci: release workflow signs+notarizes+staples on v* tags (secrets from CI)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Human runbook (docs/SIGNING.md)

**Files:** Create `docs/SIGNING.md`.

A concise operator guide: prerequisites, obtaining each credential, setting CI secrets, running locally, expected verification output, and rotation. (Pure prose — no secrets.)

- [ ] **Step 1: Write `docs/SIGNING.md`** covering:
  - **Prerequisites:** Apple Developer Program membership; a **Developer ID Application** certificate (+ private key) installed in the login keychain; an **App Store Connect API key** with the *Developer* role (issuer id, key id, downloaded `AuthKey_*.p8` — note it is downloadable only once).
  - **The five signing env vars + two CI cert secrets + the `.p8` base64 secret** (reproduce the inputs table and the CI secrets table from Tasks 5/8).
  - **Local run:** export the five vars, then `SENANI_MAKE_DMG=1 Scripts/package_and_sign.sh <version> <build>`.
  - **Expected PASS output** (copy the exact `valid on disk` / `Accepted` / `The staple and validate action worked!` / `accepted … source=Notarized Developer ID` lines from Task 6).
  - **CI:** push a `v*` tag → the release job runs; artifacts attach to the GitHub Release.
  - **Entitlements rationale** (link the "Entitlements rationale" section above; reiterate: hardened runtime, no sandbox, no telemetry).
  - **Rotation / revocation:** how to replace an expired cert or rotate the ASC key (re-export `.p12`/`.p8`, re-base64, update the two/one secrets; no code change).
  - **Troubleshooting:** notarization `Invalid` → `xcrun notarytool log <id> …`; the top 3 causes (a nested binary missing `--options runtime`/`--timestamp`, an unsigned helper, a hardened-runtime entitlement the binary actually needs).

- [ ] **Step 2: Lint markdown links/format** (best-effort):

```
python3 -c "p=open('docs/SIGNING.md').read(); assert 'Notarized Developer ID' in p and 'package_and_sign.sh' in p; print('SIGNING.md OK')"
```

Expected: `SIGNING.md OK`.

- [ ] **Step 3: Commit.**

```
git add docs/SIGNING.md
git commit -m "docs: SIGNING.md runbook (credentials, secrets, local + CI, verification, rotation)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Roadmap update + finish

**Files:** Modify `docs/ROADMAP.md`.

- [ ] **Step 1: Check the Deferred box.** In `docs/ROADMAP.md`, change `- [ ] Code signing + notarization` under "Deferred — Packaging & licensing" to `- [x] Code signing + notarization` and append ` (see Scripts/package_and_sign.sh + docs/SIGNING.md)`.

- [ ] **Step 2: Final repo-wide secret-leak sweep** (verification, must pass before merge):

```
git grep -nE 'BEGIN (RSA |EC )?PRIVATE KEY|AuthKey_[A-Z0-9]+\.p8|-----BEGIN' -- . ':!docs/SIGNING.md' ':!Scripts/*' || echo "no embedded keys found"
git ls-files | grep -E '\.(p8|p12|mobileprovision)$' && echo "LEAK: secret file tracked" || echo "no secret files tracked"
```

Expected: `no embedded keys found` and `no secret files tracked`. **If either fails, STOP and remove the leak before any commit.**

- [ ] **Step 3: Commit.**

```
git add docs/ROADMAP.md
git commit -m "docs: mark Code signing + notarization done in ROADMAP

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4:** Use superpowers:finishing-a-development-branch to open the PR (do not merge to default without the human). The PR body MUST paste the Task-6 verification output as evidence and end with the standard generated-with line.

---

## Self-Review

**Goal requirement → task mapping:**

- **SwiftPM executable → signable `.app` (bundle layout + Info.plist + icon + entitlements); recommend & justify the minimal path** → "Why a packaging script, not an Xcode app target" justifies the `swift build` + script choice (consistent with reconciliation §1 + the app-shell plan's own forecast); Task 3 (Info.plist `in.quantana.senani`, arm64, macOS 14), Task 4 (icon from `assets/senani-logo.svg`), Task 2 (entitlements), Task 5 step 2 (assembles `Contents/{MacOS,Resources}` + PkgInfo). ✅
- **Sign with Developer ID Application + hardened runtime + secure timestamp + the RIGHT entitlements (outbound HTTPS to Google + own-file r/w + Keychain)** → Task 5 step 3 (`--options runtime --timestamp --sign "$SENANI_SIGN_IDENTITY"`, inside-out, `--entitlements` on the outer app); Task 2 + "Entitlements rationale" justify `allow-jit` (MLX) + `network.client` (HTTPS) and explain that own-file r/w and Keychain need **no** entitlement for a non-sandboxed Developer ID app. ✅
- **Notarize via `xcrun notarytool submit --wait` with an App Store Connect API key (flagged input); staple** → Task 5 steps 5 (`notarytool submit --wait` with `--issuer/--key-id/--key`) + `stapler staple`; the API key is a flagged HUMAN-SUPPLIED INPUT (`SENANI_ASC_*`). `altool` is explicitly rejected. ✅
- **Verify: `codesign --verify --deep --strict`, spctl assessment, `stapler validate` — with expected PASS output** → Task 5 steps 4 & 6 run them; Task 6 step 3 lists the EXACT expected lines (`valid on disk`, `satisfies its Designated Requirement`, `Accepted`, `The staple and validate action worked!`, `The validate action worked!`, `accepted / source=Notarized Developer ID`); Task 6 step 4 proves it survives the quarantine bit. ✅
- **Reproducible `Scripts/package_and_sign.sh` + CI job on tag with secrets from CI secrets (documented, not committed)** → Task 5 (the script, env-driven, fail-fast guards, dmg optional) + Task 8 (`release.yml` on `v*`, temp-keychain import, `.p8` from base64, cleanup step, artifacts to the Release) + Task 7 (pinned keychain-import commands) + Task 9 (`docs/SIGNING.md` documents all secrets). ✅
- **Every secret flagged as human input, never hard-coded** → HUMAN-SUPPLIED INPUTS table (5 signing/notarization inputs) + Task 8 CI-secrets table (7 GitHub secrets incl. the 2 cert + 1 key base64); Task 5 step 3 proves the script fails cleanly with no secrets; Task 1 + Task 10 step 2 verify `.gitignore` blocks and no key/secret file is tracked. ✅
- **Entitlements rationale: NO telemetry; only the access actually needed** → dedicated "Entitlements rationale" section: only `allow-jit` + `network.client`, with an explicit "Deliberately ABSENT" list (sandbox, network.server, unsigned-exec-memory, disable-library-validation, any analytics). ✅

**Infra-plan discipline:** no Swift unit tests; every task is bite-sized with EXACT shell commands and EXPECTED output as the pass condition; frequent commits with the required trailer; the only credential-gated task (Task 6) is clearly flagged as human-run.

**Flagged build-order dependency:** this plan requires the app-shell plan (`SenaniApp` builds in release) to have landed — Task 1 step 1 stops if `swift build -c release` fails.

**Known residual risks (flagged for the human):** (1) if `swift build` vendors MLX dylibs/bundles, the inside-out `find`-and-sign loop (Task 5) must reach them — verified by `codesign --verify --deep --strict`; if a nested item is missed, notarization returns `Invalid` and the `notarytool log` names it. (2) The Xcode path in CI is pinned to `/Applications/Xcode_16.app`; bump it if the `macos-14` runner image changes. (3) First notarization of a new bundle id can take a few minutes — `--wait` blocks until Apple returns `Accepted`/`Invalid`.
