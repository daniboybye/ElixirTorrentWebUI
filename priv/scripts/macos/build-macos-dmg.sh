#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

APP_DISPLAY_NAME="ElixirTorrent Web"
EXECUTABLE_NAME="ElixirTorrentWebUI"
# --no-deps-check: these probes only read mix.exs, and must not fail (and fall
# back to a stale default) just because deps are not fetched or locked yet.
mix_config() {
  mix run -e "IO.write(Mix.Project.config()[:$1])" --no-start --no-compile --no-deps-check 2>/dev/null
}
VERSION="$(mix_config version || echo 0.1.0)"
# mix.exs builds against the sibling ../ElixirTorrent checkout when it exists
# (or ELIXIR_TORRENT_PATH), with its own lock; only the Hex build is held to the
# committed mix.lock.
LOCKFILE="$(mix_config lockfile || echo mix.lock)"
DIST="$ROOT/dist"
APP="$DIST/${APP_DISPLAY_NAME}.app"
STAGING="$DIST/dmg-staging"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ARCH_TAG="arm64" ;;
  x86_64) ARCH_TAG="x64" ;;
  *)
    echo "error: unsupported macOS architecture: $ARCH" >&2
    exit 1
    ;;
esac

DMG="$DIST/${APP_DISPLAY_NAME}-${VERSION}-macos-${ARCH_TAG}.dmg"

if [[ ! -f "$ROOT/priv/macos/AppIcon.icns" ]]; then
  echo "==> Generating app icon…"
  python3 "$ROOT/priv/scripts/macos/generate-app-icon.py"
fi

if [[ -d "$ROOT/priv/macos/AppIcon.icon" && ! -f "$ROOT/priv/macos/Assets.car" ]]; then
  if ! "$ROOT/priv/scripts/macos/build-liquid-glass-icon.sh"; then
    echo "warning: Liquid Glass icon requires Xcode 26+; using AppIcon.icns fallback" >&2
  fi
fi

echo "==> Building release (prod, desktop)…"
export ELIXIR_TORRENT_DESKTOP_BUILD=1
export MIX_ENV=prod

if [[ "$LOCKFILE" == "mix.lock" ]]; then
  echo "==> Engine: elixir_torrent from Hex (mix.lock)"
  mix deps.get --only prod --check-locked
else
  echo "==> Engine: local checkout (${LOCKFILE})"
  mix deps.get --only prod
fi
MIX_ENV=prod mix compile
mix phx.digest.clean --all
mix assets.deploy

RELEASE="$ROOT/_build/prod/rel/elixir_torrent_web_ui"

rm -rf "$RELEASE"
mix release --overwrite

echo "==> Assembling ${APP_DISPLAY_NAME}.app…"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/priv/macos/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP/Contents/Info.plist"

echo "==> Compiling native Dock launcher…"
swiftc "$ROOT"/priv/macos/src/*.swift \
  -o "$APP/Contents/MacOS/${EXECUTABLE_NAME}" \
  -framework AppKit \
  -framework IOKit \
  -swift-version 6 \
  -strict-memory-safety \
  -O
chmod +x "$APP/Contents/MacOS/${EXECUTABLE_NAME}"

cp -R "$RELEASE" "$APP/Contents/Resources/rel"

if [[ -f "$ROOT/priv/macos/AppIcon.icns" ]]; then
  cp "$ROOT/priv/macos/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

if [[ -f "$ROOT/priv/macos/TorrentDocument.icns" ]]; then
  cp "$ROOT/priv/macos/TorrentDocument.icns" "$APP/Contents/Resources/TorrentDocument.icns"
fi

if [[ -f "$ROOT/priv/macos/Assets.car" ]]; then
  cp "$ROOT/priv/macos/Assets.car" "$APP/Contents/Resources/Assets.car"
fi

echo "==> Sealing app bundle…"
CODESIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Creating DMG…"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# `diskutil image` (macOS 15+) replaces the deprecated `hdiutil create`; it
# overwrites an existing destination like `-ov` did, but prints percentage
# progress on stdout, hence the redirect.
diskutil image create from \
  --format UDZO \
  --volumeName "$APP_DISPLAY_NAME" \
  "$STAGING" \
  "$DMG" >/dev/null

rm -rf "$STAGING"

echo "==> Done"
echo "    App: $APP"
echo "    DMG: $DMG"
