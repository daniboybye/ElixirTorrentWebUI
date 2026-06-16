#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ICON_BUNDLE="$ROOT/priv/macos/AppIcon.icon"
BUILD_DIR="$ROOT/priv/macos/icon-build"
ASSETS_CAR="$ROOT/priv/macos/Assets.car"

if [[ ! -d "$ICON_BUNDLE" ]]; then
  echo "error: missing $ICON_BUNDLE (run mix mac.icon first)" >&2
  exit 1
fi

if ! xcrun --find actool >/dev/null 2>&1; then
  echo "error: actool not found (install Xcode 26+)" >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Compiling Liquid Glass icon with actool…"
xcrun actool "$ICON_BUNDLE" \
  --compile "$BUILD_DIR" \
  --app-icon AppIcon \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --errors

if [[ ! -f "$BUILD_DIR/Assets.car" ]]; then
  echo "error: actool did not produce Assets.car" >&2
  exit 1
fi

cp "$BUILD_DIR/Assets.car" "$ASSETS_CAR"

# Keep iconutil-generated AppIcon.icns — actool's fallback .icns drops the purple
# fill and renders a tiny T on a dark plate.

echo "==> Liquid Glass icon ready: $ASSETS_CAR"
