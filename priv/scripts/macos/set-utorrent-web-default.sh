#!/usr/bin/env bash
set -euo pipefail

# Dev/testing convenience: hands the default `.torrent`/`magnet:` handler
# back to uTorrent Web, so "Set as default" in ElixirTorrent Web's own
# Settings/banner has something to actually change on the next test pass.
# Mirrors set-magnet-default-handler.sh, but also targets the real shared
# `org.bittorrent.torrent` UTI — that one, not our own exported UTI, is what
# real `.torrent` files on disk carry (see DefaultHandlerCoordinator in
# priv/macos/Launcher.swift).

APP_PATH="${1:-/Applications/uTorrent Web.app}"
BUNDLE_ID="com.bitTorrent.utweb"
TORRENT_UTI="org.bittorrent.torrent"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "==> Registering ${APP_PATH} with Launch Services..."
"${LSREGISTER}" -f -R -trusted "${APP_PATH}"

echo "==> Setting default handler for .torrent files and magnet: links to ${BUNDLE_ID}..."
swift - <<SWIFT
import Foundation
import CoreServices

let bundleID = "${BUNDLE_ID}" as CFString
let torrentUTI = "${TORRENT_UTI}" as CFString

func torrentHandler() -> String? {
    LSCopyDefaultRoleHandlerForContentType(torrentUTI, .viewer)?.takeRetainedValue() as String?
}

func magnetHandler() -> String? {
    LSCopyDefaultHandlerForURLScheme("magnet" as CFString)?.takeRetainedValue() as String?
}

let magnetStatus = LSSetDefaultHandlerForURLScheme("magnet" as CFString, bundleID)
if magnetStatus != noErr {
    fputs("error: LSSetDefaultHandlerForURLScheme returned \\(magnetStatus)\\n", stderr)
    exit(1)
}

// LSSetDefaultRoleHandlerForContentType can report success before
// LaunchServices has actually persisted the change (see awaitStatus() in
// Launcher.swift) — poll our own read-back for a few seconds rather than
// trusting the return code alone. Call it exactly ONCE: this API prompts
// the user for confirmation on modern macOS, and calling it again on every
// retry — as an earlier version of this script did — fired that prompt
// once per iteration, up to 40 times, instead of once.
let lastTorrentStatus = LSSetDefaultRoleHandlerForContentType(torrentUTI, .viewer, bundleID)
var converged = false

for _ in 0..<40 {
    if torrentHandler()?.caseInsensitiveCompare("${BUNDLE_ID}") == .orderedSame {
        converged = true
        break
    }

    usleep(150_000)
}

print("Default magnet handler is now: \\(magnetHandler() ?? "<none>")")
print("Default .torrent handler is now: \\(torrentHandler() ?? "<none>")")

if !converged {
    let warning = "warning: LaunchServices did not confirm ${BUNDLE_ID} as the .torrent handler "
        + "after ~6s (last LSSetDefaultRoleHandlerForContentType status: \\(lastTorrentStatus)). "
        + "This can happen if another registered app (e.g. ElixirTorrent Web, qBittorrent) also "
        + "claims org.bittorrent.torrent with Owner rank and LaunchServices is slow to hand it "
        + "over. Retry this script once more, or set it manually: select a .torrent file in "
        + "Finder, press Command-I, choose uTorrent Web under \\"Open with\\", then click "
        + "\\"Change All\\"."
    fputs(warning + "\\n", stderr)
}
SWIFT

echo "==> Done."
