# Security Policy

## Supported Versions

Only the [latest GitHub release](https://github.com/daniboybye/ElixirTorrentWebUI/releases/latest) receives security fixes. Older releases are not patched — upgrade to the latest one to pick up a fix.

The BitTorrent protocol itself lives in the [`elixir_torrent`](https://github.com/daniboybye/ElixirTorrent) engine. Vulnerabilities in the wire protocol, DHT, trackers, peer handling, encryption, or on-disk piece storage belong in [that project's security policy](https://github.com/daniboybye/ElixirTorrent/security/policy). This repository covers the Phoenix/LiveView UI, the HTTP endpoint, and the macOS and Windows desktop shells.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report privately via [GitHub Security Advisories](https://github.com/daniboybye/ElixirTorrentWebUI/security/advisories/new). This opens a private discussion with the maintainer and lets a coordinated fix ship (with credit, if you'd like) before any public disclosure.

Expect an initial response within a few days. If the report is confirmed, a fix will be prepared and released as a new version, with the advisory published alongside it.

## Scope notes

Findings that are especially relevant here:

- **Reachability of the UI.** The Phoenix endpoint binds loopback (`127.0.0.1`) by default and is meant to be reachable only from the machine it runs on. Anything that exposes it beyond that, or lets another local user or a web page in the browser drive it (CSRF, WebSocket origin checks, DNS rebinding), is in scope.
- **Path handling.** Download directories, `.torrent` uploads, range-streamed media, and image previews all turn user-controlled input into filesystem access. Traversal outside the configured download directory is in scope.
- **Desktop shells.** The Swift launcher (`priv/macos/`) and the C# launcher (`priv/windows/Launcher/`) register `.torrent` and `magnet:` handlers, so they process input handed over by the OS from arbitrary sources.
- **Secret leakage in logs.** Full magnet URIs, passkeys, and private tracker credentials must not reach production logs. A log line that leaks one is a valid report.

Release artifacts are published with `.sha256` checksum files — verify the checksum after downloading a DMG or ZIP.
