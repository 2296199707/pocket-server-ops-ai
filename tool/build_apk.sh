#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-/www/mobile-agent-tooling/flutter/bin/flutter}"
PUB_CACHE_DIR="${PUB_CACHE_DIR:-/www/mobile-agent-tooling/pub-cache}"
ANDROID_SDK_DIR="${ANDROID_SDK_DIR:-/www/mobile-agent-tooling/android-sdk}"
BUILD_MODE="${1:-debug}"

if [[ "$BUILD_MODE" != "debug" && "$BUILD_MODE" != "release" ]]; then
  printf 'Usage: %s [debug|release]\n' "$0" >&2
  exit 2
fi

ANDROID_HOME="$ANDROID_SDK_DIR" \
ANDROID_SDK_ROOT="$ANDROID_SDK_DIR" \
PUB_CACHE="$PUB_CACHE_DIR" \
  "$FLUTTER_BIN" build apk "--$BUILD_MODE"

VERSION_LINE="$(sed -n 's/^version: //p' "$PROJECT_DIR/pubspec.yaml" | head -n 1)"
BUILD_NAME="${VERSION_LINE%%+*}"
APK_DIR="$PROJECT_DIR/build/app/outputs/flutter-apk"
cp "$APK_DIR/app-${BUILD_MODE}.apk" \
  "$APK_DIR/pocket-server-ops-ai-v${BUILD_NAME}-${BUILD_MODE}.apk"
printf 'Named APK: %s\n' \
  "$APK_DIR/pocket-server-ops-ai-v${BUILD_NAME}-${BUILD_MODE}.apk"
