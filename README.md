# ElixirTorrentWebUI

Phoenix (LiveView) Web UI for the `elixir_torrent` BitTorrent engine.

## Goal

Build a **stable, correct, long-running BitTorrent client UI** on top of an Elixir/OTP engine.
The engine lives in a separate project (sibling folder) and this repo is the **UI + product shell**.

## Architecture

- **Engine**: [`elixir_torrent`](https://hex.pm/packages/elixir_torrent) — Elixir/OTP BitTorrent implementation
  ([Hex docs](https://hexdocs.pm/elixir_torrent/readme.html) ·
  [GitHub](https://github.com/daniboybye/ElixirTorrent))
- **UI server**: Phoenix + LiveView (local HTTP + WebSocket)
- **Desktop (macOS)**: `mix mac.dmg` bundles a Swift launcher + `mix release`
  into `ElixirTorrent Web.app`; the UI still runs in the system browser.

### Process model

This application starts the engine on boot:

- `ElixirTorrentWebUI.Application` calls `Application.ensure_all_started(:elixir_torrent)`
- Phoenix endpoint listens on loopback only by default (`127.0.0.1`)

## Tech stack

- **Elixir**: 1.19.x
- **Phoenix**: 1.8.x
- **Phoenix LiveView**: 1.1.x
- **Bandit**: HTTP server
- **Tailwind + ESBuild**: assets pipeline

## Development setup

From the repo root:

```bash
mix setup
mix phx.server
```

Open `http://127.0.0.1:4000`.

`mix setup` also runs `mix mac.icon` to generate app icons. That step needs
**Python 3** and **Pillow** (`pip install Pillow`).

## macOS desktop app

Build a local `.app` bundle and `.dmg` installer:

```bash
mix mac.dmg
```

Output lands in `dist/` (e.g. `ElixirTorrent Web.app`,
`ElixirTorrent Web-0.1.0-macos-arm64.dmg` on Apple Silicon, or `…-macos-x64.dmg`
on Intel).

Icon generation (`mix mac.icon`, also part of `mix setup`):

- **Liquid Glass** (`Assets.car` for macOS 26+): requires **Xcode 26+**
  (`xcrun actool`). Without it, the build still produces a classic `.icns`
  fallback icon.
- **Python 3 + Pillow** for `priv/scripts/generate-app-icon.py`.

## Engine dependency

The canonical, committed dependency is the published Hex package:

```elixir
{:elixir_torrent, "~> 0.1.2"}
```

`mix.exs` resolves this dynamically. By default the Hex version is used, so a
fresh clone just needs `mix deps.get`.

### Local development against the engine

When iterating on both this UI and the engine in tandem, you can override the
source with a path on disk by setting the `ELIXIR_TORRENT_PATH` environment
variable:

```bash
export ELIXIR_TORRENT_PATH=../ElixirTorrent
mix deps.get
mix phx.server
```

Notes:

- `mix.lock` only stores the Hex version. The path override does not write to
  the lockfile, so you can switch back to Hex any time with
  `unset ELIXIR_TORRENT_PATH && mix deps.compile elixir_torrent --force`.
- The Hex version is what gets shipped and what CI uses. Always release a new
  Hex version of `elixir_torrent` before bumping the requirement here.
- Don't commit changes that only work against an unreleased local engine.

## Security notes (local UI)

- The endpoint is bound to loopback (`127.0.0.1`) in dev config.
- Before exposing anything beyond localhost, we should add auth (token/cookie) and
  review any endpoints that could control downloads or read files.

## Roadmap (high level)

- LiveView dashboard: torrents list + status + speeds
- Torrent details: pieces/peers/trackers/errors
- Controls: add torrent, start/stop, remove
- Packaging: `mix mac.dmg` (macOS `.app` + `.dmg`)
