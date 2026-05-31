#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
VENDOR_DIR="$ROOT/Vendor/EmbeddingGemma-MLX"
REPO_URL="https://github.com/gradinnovate/EmbeddingGemma-MLX.git"

if [[ -d "$VENDOR_DIR/.git" ]]; then
  git -C "$VENDOR_DIR" fetch --depth=1 origin main
  git -C "$VENDOR_DIR" checkout main
  git -C "$VENDOR_DIR" merge --ff-only origin/main
else
  mkdir -p "$(dirname "$VENDOR_DIR")"
  git clone --depth=1 --filter=blob:none --sparse "$REPO_URL" "$VENDOR_DIR"
fi

git -C "$VENDOR_DIR" sparse-checkout set mlx-swift-examples SwiftTests
cp "$VENDOR_DIR/SwiftTests/default.metallib" "$ROOT/default.metallib"
if [[ -d "$REPO_ROOT/SenaniApp" ]]; then
  cp "$VENDOR_DIR/SwiftTests/default.metallib" "$REPO_ROOT/SenaniApp/default.metallib"
fi

echo "EmbeddingGemma MLX package installed at:"
echo "  $VENDOR_DIR/mlx-swift-examples"
echo "MLX Metal library copied to:"
echo "  $ROOT/default.metallib"
if [[ -d "$REPO_ROOT/SenaniApp" ]]; then
  echo "  $REPO_ROOT/SenaniApp/default.metallib"
fi
echo
echo "Build the optional adapter with:"
echo "  cd $ROOT && swift build --target SenaniInferenceEmbeddingGemmaMLX"
