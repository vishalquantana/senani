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
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"

# executable
cp "${PRODUCT_BIN}" "${APP}/Contents/MacOS/Senani"
chmod +x "${APP}/Contents/MacOS/Senani"

# Embed Sparkle
SPARKLE_FW="${APP_PKG}/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "${SPARKLE_FW}" ]]; then
    cp -R "${SPARKLE_FW}" "${APP}/Contents/Frameworks/"
    # Fix rpath so Senani can find Sparkle in Contents/Frameworks
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP}/Contents/MacOS/Senani" || true
fi

# icon
"${SCRIPT_DIR}/make_icon.sh"
cp "${SCRIPT_DIR}/Senani.icns" "${APP}/Contents/Resources/Senani.icns"

# Info.plist (substitute version tokens and Sparkle keys)
sed -e "s/@@VERSION@@/${VERSION}/g" -e "s/@@BUILD@@/${BUILD_NUMBER}/g" \
    -e "s|@@SU_FEED_URL@@|${SENANI_SU_FEED_URL:-https://updates.example.invalid/appcast.xml}|g" \
    -e "s/@@SU_PUBLIC_ED_KEY@@/${SENANI_SU_PUBLIC_ED_KEY:-REPLACE_WITH_SUPublicEDKey_FROM_generate_keys}/g" \
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
