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
