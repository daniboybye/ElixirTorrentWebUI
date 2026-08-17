# Contributing to ElixirTorrent Web

Thanks for taking a look at this project — contributions are genuinely welcome, whether that's a bug report, a translation fix, a UI improvement, or just a question. No contribution is too small to be useful, and no question is too basic to ask.

This repository is the **UI and desktop product shell**. The BitTorrent protocol itself lives in the [`elixir_torrent`](https://github.com/daniboybye/ElixirTorrent) engine — if your change is about peers, trackers, DHT, or piece storage, it probably belongs there instead.

## Ways to help

- **Report a bug** — [open an issue](https://github.com/daniboybye/ElixirTorrentWebUI/issues/new). Include what you expected, what happened, your OS, and (if you can) the relevant slice of the log. Please redact magnet URIs and passkeys before pasting logs.
- **Suggest an improvement** — an issue works fine for this too; it's fine if it's just an idea rather than a fully worked-out proposal.
- **Improve translations** — the UI ships 64 Gettext locale catalogs under `priv/gettext/`, and most of them could use a native speaker's eye.
- **Send a pull request** — for anything beyond a typo fix, opening an issue first is a good way to make sure the approach makes sense before you put time into it.

Found a security vulnerability instead? Please don't open a public issue for that — see [SECURITY.md](SECURITY.md) for how to report it privately.

## Getting set up

```bash
git clone https://github.com/daniboybye/ElixirTorrentWebUI.git
cd ElixirTorrentWebUI
mix setup
mix phx.server
```

Requires Elixir 1.20+ on OTP 29 (see `.tool-versions` for the exact toolchain CI pins). By default the engine is pulled from Hex. To develop against a local engine checkout instead, point `ELIXIR_TORRENT_PATH` at it — but never commit the resulting `mix.lock` change:

```bash
ELIXIR_TORRENT_PATH=../ElixirTorrent mix deps.get
```

The native launchers are optional for most work and only build on their own platform: the Swift shell (`priv/macos/src/`) needs Xcode with the Swift 6 toolchain, and the C# WinUI 3 shell (`priv/windows/Launcher/`) needs the .NET 10 SDK on Windows 11 x64.

## Before opening a pull request

The same checks CI runs are available locally:

```bash
mix format
mix quality           # compile --warnings-as-errors, dialyzer, credo --all, sobelow
timeout 60s mix test
mix coveralls         # coverage gate, see coveralls.json
```

For changes to the native launchers, run their own checks on the matching platform:

```bash
swiftlint lint --strict                                   # macOS, priv/macos/
dotnet build priv/windows/Launcher -c Release             # Windows 11 x64
```

A few conventions this codebase follows, worth keeping in mind:

- **The engine boundary is deliberate.** UI code talks to the engine through `ElixirTorrentWebUI.Engine` rather than calling `ElixirTorrent` directly, which is what keeps the UI testable without a live swarm.
- **Tests are event-driven, not timing-based.** Avoid `Process.sleep`/`:timer.sleep` in tests — use messages, monitors, or `:sys.get_state` barriers instead. Flaky sleep-based tests are worse than no test. Keep a test run comfortably inside the 60-second CI watchdog.
- **Every user-facing string goes through Gettext**, and new strings should land translated across the configured locale catalogs in the same commit.
- **Logs stay clean.** No full magnet URIs, passkeys, or routine lifecycle chatter in production logs; expected diagnostics belong at `debug`.
- **Commit messages** follow a lowercase [Conventional Commits](https://www.conventionalcommits.org/)-style prefix, e.g. `fix(live): ...`, `feat(settings): ...`, `test: ...`, `docs: ...`.
- New functionality should come with tests; a bug fix is a good opportunity to add a regression test for it.

None of this needs to be perfect before you open a PR — it's fine to ask for help getting there. `Build WebUI, Test and Analyze` has to pass before a PR can merge, and the platform workflows (`Build macOS`, `Build Windows`) run for changes that touch the desktop shells.

## Code of conduct

Be respectful and assume good faith — that's really the whole policy. Disagreements about code and design are normal and welcome; personal attacks aren't.
