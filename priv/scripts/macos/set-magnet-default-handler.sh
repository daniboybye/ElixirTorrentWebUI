#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/ElixirTorrent Web.app}"
BUNDLE_ID="com.elixirtorrent.webui"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Registering $APP_PATH with Launch Services…"
"$LSREGISTER" -f -R -trusted "$APP_PATH"

echo "==> Setting default handler for magnet: links to $BUNDLE_ID…"
swift - <<SWIFT
import Foundation
import CoreServices

let status = LSSetDefaultHandlerForURLScheme(
    "magnet" as CFString,
    "$BUNDLE_ID" as CFString
)

if status != 0 {
    fputs("error: LSSetDefaultHandlerForURLScheme returned \\(status)\\n", stderr)
    exit(1)
}

if let handler = LSCopyDefaultHandlerForURLScheme("magnet" as CFString)?
    .takeRetainedValue() as String? {
    print("Default magnet handler is now: \\(handler)")
} else {
    print("Default magnet handler updated.")
}
SWIFT

cat <<'EOF'

==> Done.

Notes:
- Default for .torrent files and default for magnet: links are separate settings.
- If a browser still opens qBittorrent, check the browser's protocol handlers:
  • Chrome: chrome://settings/handlers
  • Firefox: Settings → General → Applications → magnet
EOF
