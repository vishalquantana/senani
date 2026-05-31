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
for spec in     "16 icon_16x16" "32 icon_16x16@2x"     "32 icon_32x32" "64 icon_32x32@2x"     "128 icon_128x128" "256 icon_128x128@2x"     "256 icon_256x256" "512 icon_256x256@2x"     "512 icon_512x512" "1024 icon_512x512@2x"; do
    px="${spec%% *}"; name="${spec##* }"
    sips -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}.png" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "${SCRIPT_DIR}/Senani.icns"
echo "Wrote ${SCRIPT_DIR}/Senani.icns"
