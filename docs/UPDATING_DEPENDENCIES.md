# Updating dependencies and tooling

A repeatable procedure for bringing every moving part of the WebUI up to date:
the engine, Hex dependencies, the Erlang/Elixir toolchain, the analysis and
formatting tools, the asset tooling, and the GitHub Actions workflows. Run it
roughly once a month, or whenever Dependabot opens a batch of PRs. The engine
repository has the same procedure (`docs/UPDATING_DEPENDENCIES.md` in
ElixirTorrent); the Erlang/Elixir pair and the shared tools (credo, dialyxir,
sobelow, excoveralls) should stay aligned between the two repositories.

> Rules that apply to the whole procedure
>
> - Language of commit messages, PR titles, PR descriptions and PR comments is
>   **English**.
> - Work on a feature branch, never on `main`.
> - Delete the feature branch (local and remote) once it is merged.
> - A PR produced by an autonomous cloud agent must be validated locally on a
>   developer machine (run the app, real torrents) before merge.
> - One concern per PR where practical: toolchain, Hex deps and Actions can
>   each be reverted independently.

## 0. Preparation

1. `git switch main && git pull`, then `git switch -c chore/update-deps-YYYY-MM`.
2. Build against the published engine, as CI does:
   `ELIXIR_TORRENT_HEX=1 mix deps.get` (see `engine_path/0` in `mix.exs`; on a
   developer machine with a sibling `../ElixirTorrent` checkout the local
   engine is used by default and `mix.local.lock` is used instead of
   `mix.lock`). **Always commit changes to `mix.lock`, never `mix.local.lock`,
   and do the lock-changing steps below with `ELIXIR_TORRENT_HEX=1` set.**
3. Make sure the baseline is green first:
   `mix format --check-formatted && mix quality && mix test`.
4. Merge or close open Dependabot PRs that overlap with this run
   (`.github/dependabot.yml`; weekly; groups `dev-and-test-tooling`,
   `phoenix` and `github-actions`).

## 1. Erlang and Elixir

| File | What to change |
| --- | --- |
| `.tool-versions` | `erlang X.Y.Z` and `elixir X.Y.Z-otp-N` (OTP major must match) |
| `mix.exs` | `elixir: "~> 1.NN"`, only if the minimum supported Elixir changes |
| `README.md` / `CONTRIBUTING.md` | any mention of required Erlang/Elixir versions |
| `.github/workflows/*.yml` | versions come from `.tool-versions` via `erlef/setup-beam` (`version-type: strict`); there is no separate matrix |
| `priv/scripts/` (macOS and Windows packaging) | check whether a script pins or detects OTP/Elixir versions |

Steps:

1. Prefer to take the pair that the engine already uses (update the engine
   first, see its procedure).
2. Verify `erlef/setup-beam` can install it on **every** runner used here,
   including macOS and Windows: <https://github.com/erlef/setup-beam>.
   `build-macos.yml` sets `ImageOS: macos26` as a workaround for the
   `xcode-27` image; re-check whether the current `setup-beam` knows the real
   image and drop the workaround if so.
3. Edit `.tool-versions`, `asdf install` (or `mise install`),
   `rm -rf _build deps`, then run the full check (section 6).
4. A new OTP major can change the release/packaging output; build the
   release once locally (`mix mac.dmg` on macOS) before merging.

## 2. Engine (`elixir_torrent`)

1. Latest published version: `mix hex.info elixir_torrent`.
2. Update the requirement in `elixir_torrent_dep/0` in `mix.exs`
   (`{:elixir_torrent, "~> X.Y.0"}`), then
   `ELIXIR_TORRENT_HEX=1 mix deps.update elixir_torrent`.
3. Read the engine `CHANGELOG.md` for API or config changes and adapt
   `lib/`. Validate on a developer machine against real torrents; the engine
   can also be tested before it is published with
   `ELIXIR_TORRENT_PATH=../ElixirTorrent`.

## 3. Hex dependencies

1. `ELIXIR_TORRENT_HEX=1 mix hex.outdated --all`.
2. Update within current requirements: `ELIXIR_TORRENT_HEX=1 mix deps.update --all`.
   Majors one at a time: raise the requirement in `mix.exs`, `mix deps.update
   <name>`, read the changelog, adapt the code.
3. Specific to this repo:
   - **Phoenix family** (`phoenix`, `phoenix_live_view`, `phoenix_html`,
     `phoenix_live_dashboard`, `phoenix_live_reload`) move together; update
     them in one step. After a LiveView major, check `compilers:` and
     `listeners:` in `mix.exs` and run the whole test suite.
   - **`esbuild` and `tailwind`** are Hex wrappers that also pin the version of
     the downloaded binary in `config/config.exs` (`version:`). Bump that
     version too, then `mix assets.setup && mix assets.build`; check the UI
     visually (Tailwind majors change defaults).
   - **`heroicons`** is a git dependency pinned to `tag: "v2.2.0"` and is
     ignored by Dependabot on purpose. A bump is a design decision: update the
     tag only deliberately and check the icons in the UI.
   - **`lazy_html`** is test-only and compiles native code; check it builds on
     the new OTP.
4. Hygiene checks (the same ones CI runs):
   ```bash
   ELIXIR_TORRENT_HEX=1 mix deps.get
   mix deps.unlock --check-unused
   mix hex.audit
   ```
5. Commit `mix.exs` and `mix.lock` together (not `mix.local.lock`).

## 4. Analysis and formatting tools

Tools: `credo`, `dialyxir`, `sobelow`, `excoveralls`, the Elixir formatter,
`trivy`, and `swiftlint` for the macOS launcher.

1. `credo`, `dialyxir`, `sobelow`, `excoveralls` are Hex deps (section 3).
   Afterwards review config:
   - `.credo.exs`: diff against `mix credo gen.config` output into a temporary
     file; adopt new checks deliberately.
   - Dialyzer: rebuild the PLT after an OTP or dialyxir change
     (`mix dialyzer`; delete `_build/dev/dialyxir_*` if it looks stale).
   - Sobelow: the `quality` alias and CI use
     `--skip --strict --private --exit --threshold medium`; keep them in sync
     if flags change.
   - `coveralls.json`: check coverage thresholds still make sense.
2. Formatter: after a toolchain or Phoenix bump run `mix format` and commit the
   result as a separate commit. Check that `.formatter.exs` `import_deps`
   still lists the right libraries.
3. Trivy: configuration in `.trivy.yaml`. Note that the workflow currently uses
   `aquasecurity/trivy-action@master` (floating, intentional comment in the
   workflow); consider pinning it to a SHA like all other actions.
4. SwiftLint: installed with `brew install swiftlint` on the runner, so it is
   always the latest. After a new Xcode/Swift image, run
   `swiftlint lint --strict` locally and adjust `.swiftlint.yml` rules that
   were renamed or deprecated.
5. New findings are fixed in the same PR when small, otherwise recorded in the
   PR description with a follow-up issue. Never disable a check just to get a
   green build.

## 5. GitHub Actions and runner images

Workflows: `web-build-test-analyze.yml`, `build-macos.yml`,
`build-windows.yml`, `release.yml`.

1. List what is pinned:
   ```bash
   grep -RnE 'uses:|runs-on:|ImageOS|version:' .github/workflows
   ```
2. Actions are pinned to a full commit SHA with a version comment (for example
   `# v7.0.1`). Update both the SHA and the comment, using the SHA of the
   release tag (`git ls-remote --tags https://github.com/<owner>/<repo>`; for
   annotated tags use the `^{}` line). Dependabot's `github-actions` group
   normally does this; review and merge it when open.
3. Used actions include `actions/checkout`, `actions/cache`,
   `erlef/setup-beam`, `aquasecurity/trivy-action`, `codecov/codecov-action`,
   `actions/upload-artifact` (and the matching download action in
   `release.yml`); keep the upload/download majors compatible with each other.
   Read release notes for majors.
4. Runner images:
   - Linux: `ubuntu-26.04` (cheapest; used for PR checks).
   - macOS: `xcode-27`, a public-preview label. Per the comment in
     `build-macos.yml`, switch to the plain `macos-27` label once GitHub
     promotes it to GA. macOS minutes are billed 10x, so do not add macOS jobs
     to the per-PR workflow.
   - Windows: whatever `build-windows.yml` declares; check
     <https://github.com/actions/runner-images> for deprecations.
   Check for newer or deprecated images and change every occurrence.
5. Validate: `actionlint` if available, push the branch so the PR run exercises
   `web-build-test-analyze.yml`. The macOS and Windows builds run only on tags
   or manual dispatch: trigger them with **Run workflow** on the branch for any
   change to those files (or to the toolchain), and wait for them.

## 6. Verification (before opening the PR)

```bash
ELIXIR_TORRENT_HEX=1 mix deps.get
mix deps.unlock --check-unused
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors && MIX_ENV=test mix compile --warnings-as-errors
mix credo --all
mix sobelow --skip --strict --private --exit --threshold medium
mix dialyzer
MIX_ENV=test mix coveralls.json --no-compile
```

Then, on a developer machine, run the app (`mix phx.server` or the packaged
build), add a real torrent and let it download; check the UI after asset-tool
or Phoenix updates.

## 7. Pull request

- Branch `chore/update-deps-YYYY-MM`, English title such as
  `chore(deps): update toolchain, engine, Hex dependencies and CI actions`.
- The description lists, per category (toolchain, engine, Hex deps, analysis
  tools, Actions/runners): old version, new version, anything that needed code
  changes or was deliberately skipped (with the reason), and which manual
  workflow runs were triggered.
- Wait for `Build WebUI, Test and Analyze` to pass.
- If the PR was made by a cloud agent, validate locally (section 6, last
  paragraph) and only then merge.

## 8. After merging

1. Delete the feature branch locally and on the remote.
2. Release the WebUI only if the changes should reach users (follow the local
   `.claude/RELEASE.md` if you keep one; the tag triggers `release.yml`).

## WebUI follow-up from the engine

When the engine procedure changed the toolchain or released a new version,
run only sections 1 and 2 here, plus the verification in section 6.
