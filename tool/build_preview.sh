#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/www/mobile-agent-tooling/flutter/bin/flutter}"
PUB_CACHE_DIR="${PUB_CACHE_DIR:-/www/mobile-agent-tooling/pub-cache}"

PUB_CACHE="$PUB_CACHE_DIR" "$FLUTTER_BIN" build web \
  --release \
  --no-wasm-dry-run \
  --dart-define=PREVIEW_MODE=true \
  --base-href=/ \
  --output="$PROJECT_DIR/build/preview/web"
