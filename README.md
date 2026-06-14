# ElixirTorrent Web

Phoenix (LiveView) Web UI for the [`elixir_torrent`](https://hex.pm/packages/elixir_torrent)
BitTorrent engine.

## Goal

Build a **stable, correct, long-running BitTorrent client UI** on top of an Elixir/OTP engine.
The engine lives in a separate project and this repo is the **UI + desktop product shell**.

## Features

- **Torrent dashboard** — list with progress, speeds, peers, ETA, expandable file rows
- **Add & remove torrents** — `.torrent` upload via LiveView; optional delete downloaded data
- **macOS desktop app** — `mix mac.dmg` bundles a Swift launcher + release into
  `ElixirTorrent Web.app` (browser UI on loopback)

## Architecture

- **Engine**: [`elixir_torrent` ~> 0.2.0](https://hex.pm/packages/elixir_torrent)
  ([Hex docs](https://hexdocs.pm/elixir_torrent/readme.html) ·
  [GitHub](https://github.com/daniboybye/ElixirTorrent))
  — session persistence, graceful shutdown (`stop_and_serialize/1`), peer disconnect
- **UI server**: Phoenix + LiveView (local HTTP + WebSocket)
- **Desktop (macOS)**: Swift launcher starts the release, opens the browser, graceful shutdown on Quit

### Process model

On boot, `ElixirTorrentWebUI.Application` calls `Application.ensure_all_started(:elixir_torrent)`.
The Phoenix endpoint listens on loopback only by default (`127.0.0.1`).

UI code talks to the engine through `ElixirTorrentWebUI.Engine` — not `ElixirTorrent.*` directly.

## Tech stack

- **Elixir**: 1.20.x
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

`mix phx.server` and the macOS `.app` share **catalog, UI state, and `.torrent` files**
via `~/Library/Application Support/ElixirTorrentWebUI/` (see `ElixirTorrentWebUI.DataDir`).

In **dev**, the process working directory stays in the project root so Phoenix code
reloading works; engine session files and downloads land under the repo unless you
symlink `.elixir_torrent` to Application Support. The **desktop app** uses that
folder as its cwd, so torrent data and the catalog stay in sync there.

Override the data root with `ELIXIR_TORRENT_DATA_DIR` if needed.

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
{:elixir_torrent, "~> 0.2.0"}
```

Requires **elixir_torrent 0.2.0+** for session persistence APIs used by the desktop app
(`stop_and_serialize/1`, `stop_all_and_serialize/0`, `list/0`).

`mix.exs` resolves this dynamically. By default the Hex version is used, so a
fresh clone just needs `mix deps.get`.

### Local development against the engine

When iterating on both this UI and the engine in tandem, override the source with
`ELIXIR_TORRENT_PATH`:

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
- Before exposing anything beyond localhost, add auth (token/cookie) and review endpoints
  that control downloads or read files.

## Roadmap

See [`TODO.md`](TODO.md) for planned work (persistence polish, magnet links, search,
cross-platform packaging, Dock menu, and more).
