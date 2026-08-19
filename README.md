# ElixirTorrent Web

[![GitHub release](https://img.shields.io/github/v/release/daniboybye/ElixirTorrentWebUI?label=release&logo=github&color=181717)](https://github.com/daniboybye/ElixirTorrentWebUI/releases/latest) [![GitHub](https://img.shields.io/badge/source-ElixirTorrentWebUI-181717?logo=github)](https://github.com/daniboybye/ElixirTorrentWebUI) [![CI](https://img.shields.io/github/actions/workflow/status/daniboybye/ElixirTorrentWebUI/web-build-test-analyze.yml?branch=main&label=CI&logo=github)](https://github.com/daniboybye/ElixirTorrentWebUI/actions/workflows/web-build-test-analyze.yml) [![codecov](https://codecov.io/gh/daniboybye/ElixirTorrentWebUI/branch/main/graph/badge.svg)](https://codecov.io/gh/daniboybye/ElixirTorrentWebUI) [![Last commit](https://img.shields.io/github/last-commit/daniboybye/ElixirTorrentWebUI/main)](https://github.com/daniboybye/ElixirTorrentWebUI/commits/main) [![Engine](https://img.shields.io/badge/Engine-ElixirTorrent-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent) [![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Windows-lightgrey)](https://github.com/daniboybye/ElixirTorrentWebUI/releases/latest) [![License](https://img.shields.io/github/license/daniboybye/ElixirTorrentWebUI?label=license&color=blue)](LICENSE)

[![Elixir](https://img.shields.io/badge/elixir-%7E%3E%201.20-4B275F?logo=elixir)](https://elixir-lang.org) [![OTP](https://img.shields.io/badge/OTP-29-A90533?logo=erlang)](https://www.erlang.org) [![Swift](https://img.shields.io/badge/swift-6.3-F05138?logo=swift&logoColor=white)](https://www.swift.org) [![.NET](https://img.shields.io/badge/10-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com)

Phoenix (LiveView) Web UI and desktop shell for the
[`elixir_torrent`](https://hex.pm/packages/elixir_torrent) BitTorrent engine.
The goal is a **stable, correct, long-running BitTorrent client UI** on top of
an Elixir/OTP engine; the engine lives in its own project and this repo is the
**UI + desktop product**.

## Features

- **Torrent dashboard** — progress, speeds, peers, ETA, expandable file rows
- **Add & remove torrents** — `.torrent` upload, magnet links, persisted pending
  magnets, and optional removal of the downloaded data
- **Lifetime statistics** — persisted downloaded/uploaded totals and current
  aggregate speeds, with a reset action
- **Settings** — default download directory and app preferences, persisted
  across restarts
- **Localized UI** — every user-facing string is maintained in 64 Gettext locales
- **Desktop apps** — macOS `.app`/DMG and a Windows 11 portable ZIP, each with a
  native launcher that runs the release, serves the UI on loopback, registers
  `.torrent`/`magnet:` handlers, rotates logs, and shuts the engine down
  gracefully

## Architecture

- **Engine**: [`elixir_torrent`](https://hex.pm/packages/elixir_torrent)
  ([Hex docs](https://hexdocs.pm/elixir_torrent/readme.html) ·
  [GitHub](https://github.com/daniboybye/ElixirTorrent))
  — session persistence, graceful shutdown (`stop_and_serialize/1`), peer disconnect
- **UI server**: Phoenix + LiveView (local HTTP + WebSocket)
- **Desktop (macOS)**: Swift/AppKit launcher (`priv/macos/src/`)
- **Desktop (Windows 11)**: self-contained .NET 10 Win32 launcher
  (`priv/windows/Launcher/`)

### Process model

On boot, `ElixirTorrentWebUI.Application` calls `Application.ensure_all_started(:elixir_torrent)`.
The Phoenix endpoint listens on loopback only by default (`127.0.0.1`).

UI code talks to the engine through `ElixirTorrentWebUI.Engine` — not `ElixirTorrent.*` directly.

## Tech stack

- **Elixir**: 1.20.x
- **Phoenix**: 1.8.x
- **Phoenix LiveView**: 1.2.x
- **Bandit**: HTTP server
- **Tailwind + ESBuild**: assets pipeline

## Development setup

From the repo root:

```bash
mix setup
mix phx.server
```

Open `http://127.0.0.1:4000`.

`mix phx.server` and the macOS `.app` share **catalog, UI state, and `.torrent` files**
via `~/Library/Application Support/ElixirTorrentWebUI/` (see `ElixirTorrentWebUI.DataDir`).
Override the data root with `ELIXIR_TORRENT_DATA_DIR` if needed.

In **dev**, the process working directory stays in the project root so Phoenix code
reloading works; engine session files and downloads land under the repo unless you
symlink `.elixir_torrent` to Application Support. The **desktop app** uses that
folder as its cwd, so torrent data and the catalog stay in sync there.

`mix setup` also runs `mix mac.icon` to generate app icons. That step needs
**Python 3** and **Pillow** (`pip install Pillow`).

## macOS desktop app

Build a local `.app` bundle and `.dmg` installer:

```bash
mix mac.dmg
```

Output lands in `dist/` (e.g. `ElixirTorrent Web.app`,
`ElixirTorrent Web-0.4.0-macos-arm64.dmg` on Apple Silicon, or `…-macos-x64.dmg`
on Intel).

The **Liquid Glass** icon (`Assets.car`, macOS 26+) requires **Xcode 26+**
(`xcrun actool`). Without it the build still produces a classic `.icns` fallback.

## Windows 11 desktop app

Build the portable ZIP on Windows — the release embeds the Windows ERTS, so it
cannot be cross-built. Only the **.NET 10 SDK** is required; Visual Studio is not.

```powershell
pwsh .\priv\scripts\windows\build-windows-zip.ps1
```

Output lands in `dist\windows\` as
`ElixirTorrentWebUI-<version>-windows-x64.zip` plus its SHA-256 file. Extract
and run `ElixirTorrentWebUI.Launcher.exe`; mutable state lives under
`%LOCALAPPDATA%\ElixirTorrentWebUI`. See
[`priv/windows/README.md`](priv/windows/README.md) for the launcher CLI and
handler registration.

## Engine dependency

The committed dependency remains the published Hex package. While both projects
evolve together, validate the WebUI against a local Engine checkout by setting:

```bash
export ELIXIR_TORRENT_PATH=../ElixirTorrent
mix deps.get
```

The local path and Engine revision are development inputs, not committed pins.
Do not commit lock-file changes caused only by switching dependency sources.

## Tests and quality

The deterministic ExUnit/ConnTest/LiveViewTest suite has a 60-second ceiling.
ExCoveralls currently enforces the first 55% project gate (57.2% at introduction);
the roadmap raises this to 70% and then above 80%.

```bash
export ELIXIR_TORRENT_PATH=../ElixirTorrent
mix format --check-formatted
mix quality
perl -e 'alarm shift; exec @ARGV' 60 mix coveralls
```

GitHub Actions runs four workflows:

- **Build WebUI, Test and Analyze** — every pull request and every push to `main`,
  on Linux: Trivy dependency and secret scan, locked dependencies, Hex audit,
  formatting, warnings-as-errors compilation in dev and test, Credo, Sobelow,
  Dialyzer, and the coverage run uploaded to Codecov.
- **Build macOS** — SwiftLint (`--strict`) over `priv/macos/src`, the full suite on
  Apple Silicon, then the DMG and its SHA-256 checksum.
- **Build Windows** — the launcher build, the suite on Windows x64, the portable
  ZIP with its checksum, and a launcher CLI/HTTP smoke test.
- **Release** — on a semver tag: calls both platform workflows and publishes their
  artifacts to the GitHub Release, with a `dry_run` dispatch option.

The two platform workflows are reusable and deliberately do not run per pull request
— macOS runners bill 10x and Windows 2x — so they fire on tags or manual dispatch.

## Security notes (local UI)

- The endpoint is bound to loopback (`127.0.0.1`) in dev config.
- Media routes accept only torrent id/file index, resolve server-side Engine state,
  and reject traversal, absolute, drive, UNC, and NUL paths.
- Completed image previews are allow-listed, private-cache responses with
  `X-Content-Type-Options: nosniff`; paths are never accepted from HTTP clients.
- Before exposing anything beyond localhost, add auth (token/cookie) and review endpoints
  that control downloads or read files.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Security reports
go through [SECURITY.md](SECURITY.md), not public issues.

Released under the [MIT License](LICENSE).
