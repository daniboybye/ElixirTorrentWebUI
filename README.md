# ElixirTorrentWebUI

Phoenix (LiveView) Web UI for the `elixir_torrent` BitTorrent engine.

## Goal

Build a **stable, correct, long-running BitTorrent client UI** on top of an Elixir/OTP engine.
The engine lives in a separate project (sibling folder) and this repo is the **UI + product shell**.

## Architecture

- **Engine**: `../ElixirTorrent` (Elixir/OTP BitTorrent implementation)
- **UI server**: Phoenix + LiveView (local HTTP + WebSocket)
- **Desktop strategy**: start with browser UI; later we can wrap the local UI in
  Electron/Tauri/WKWebView for a native window, without changing the backend.

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

## Engine dependency

The canonical, committed dependency is the published Hex package:

```elixir
{:elixir_torrent, "~> 0.1.1"}
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
- Packaging: `mix release` + optional desktop wrapper
