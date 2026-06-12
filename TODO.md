# TODO / Roadmap

---

## Persistence & configuration

### Persist state between app launches

When the user quits and reopens the desktop app (or restarts the release), the UI
should restore the last known view of the world: active torrents, per-torrent
metadata the engine already tracks, expanded cards, theme preference, etc.

- **Engine layer:** ensure torrent session / resume data survives process restarts
(download paths, `.torrent` state, partial files).
- **UI layer:** avoid treating every launch as a blank slate; reconnect LiveView
to whatever the engine reports after boot.
- **Desktop:** data directory under `~/Library/Application Support/ElixirTorrentWebUI`
should remain the canonical workspace across launcher restarts.

### User-configurable download directory

Today downloads land in a fixed location. Add a setting (and persistence) so the
user can choose where completed and in-progress files are stored—e.g. via a folder
picker in the UI, saved to config on disk, passed to the engine on add/start.

- Validate path exists and is writable before accepting.
- Handle macOS sandbox / permissions if we move toward a stricter bundle later.
- Migration: existing torrents keep their original paths.

### Generate `SECRET_KEY_BASE` on first launch (desktop)

Replace the hardcoded desktop secret in `config/runtime.exs` with a value
generated once and stored under Application Support (e.g.
`~/Library/Application Support/ElixirTorrentWebUI/secret_key_base`).

- Read on subsequent starts; create with `mix phx.gen.secret`-equivalent entropy
on first run.
- Launcher or release boot script must ensure the file exists before Phoenix starts.
- Server deployments continue to require `SECRET_KEY_BASE` via environment variable.

---

## UI & UX (web)

### Search field

Add a filter/search control on the torrent list (by name, hash fragment, state).
Should be client-side fast filter or server-backed depending on list size; debounce
input; clear affordance; works with LiveView streams.

### Magnet link support

Allow adding torrents via `magnet:?xt=urn:btih:…` in addition to `.torrent` file
upload—paste field, drag-to-add, or OS handler. Engine adapter needs a stable API
for magnet → download session; surface errors (invalid magnet, DHT/bootstrap
failures) in flash UI.

### Open in Finder button

Per torrent (or global “open download folder”), a control that reveals the  
torrent’s data directory in Finder/macOS file manager. Implementation: resolve  
engine path for that torrent, call desktop opener (`open` on macOS) via a small  
desktop-only code path or LiveView event that the launcher does not need to own.

### Deferred disk space reservation on torrent start

When a download starts, do **not** pre-allocate the full torrent size immediately
(if the engine currently reserves upfront). Reserve space progressively or only
check free space before start with a clear error if insufficient—reduces spikes on
large torrents and matches user expectation on desktop clients.

---

## macOS desktop shell

### Active torrents in the Dock menu

Expose a native Dock menu (right-click app icon) listing active torrents with
name + progress summary; selecting an item opens the browser UI (or focuses an
existing tab). Requires AppKit changes in `Launcher.swift` (`applicationDockMenu`)
and a lightweight way to read status from the running release (HTTP JSON endpoint
or periodic poll).

### Menu bar icon (macOS)

Optional menu bar extra (status item) with quick actions: open UI, pause/resume
all, quit, maybe top-N torrents. Distinct from Dock icon; uses `NSStatusItem`.
Consider battery/menu bar clutter—may be opt-in in settings.

---

## Cross-platform packaging

### Windows / Linux executables

Parity with the macOS desktop story: ship a local release + small native launcher
(or documented `mix release` + scripts) for:

- **Windows:** `.exe` installer or portable folder; loopback bind; browser open on
start; graceful stop on exit.
- **Linux:** AppImage, `.deb`, or tarball + systemd user unit—TBD.

Shared requirements:

- Same `ELIXIR_TORRENT_DESKTOP=1` runtime behavior as macOS.
- Platform-specific icons and naming (`ElixirTorrent Web`).
- CI matrix builds per architecture (x64, arm64 where relevant).

---

