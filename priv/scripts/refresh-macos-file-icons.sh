#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/ElixirTorrent Web.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Registering $APP_PATH with Launch Services…"
"$LSREGISTER" -f -R -trusted "$APP_PATH"

echo "==> Done. Relaunch Finder (Option+right-click Dock icon → Relaunch)."
echo "    If a .torrent file still shows an old icon, open Get Info → Open with → Change All…"
