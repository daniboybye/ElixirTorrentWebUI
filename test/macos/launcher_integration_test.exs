defmodule ElixirTorrentWebUI.MacOS.LauncherIntegrationTest do
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.{CommandEnvironment, DefaultHandler}

  # Unlike LauncherTest (which only pins invariants in the Swift source),
  # this module compiles priv/macos/Launcher.swift for real and drives it
  # against the host's actual LaunchServices database — the same database the
  # packaged app registers itself with. That means every test here mutates
  # this machine's real default `.torrent`/`magnet:` handler as a side effect,
  # under the same bundle identifier the packaged app uses (a bare `swiftc`
  # binary has no bundle, so `DefaultHandlerCoordinator` falls back to the
  # hardcoded "com.elixirtorrent.webui").
  #
  # That is unacceptable as part of a routine `mix test` — on a developer's
  # Mac it would silently hijack their default torrent client — so this
  # module is excluded by default (see test/test_helper.exs) and only runs
  # via `mix test --only macos_integration`, wired into the macOS release
  # build in .github/workflows/build-macos.yml where the runner is ephemeral.
  @moduletag :macos_integration
  @moduletag timeout: 60_000

  setup_all do
    if match?({:unix, :darwin}, :os.type()) do
      {:ok, binary: compile_launcher!()}
    else
      :ok
    end
  end

  setup do
    if match?({:unix, :darwin}, :os.type()) do
      :ok
    else
      {:skip, "macOS-only: exercises Launch Services via priv/macos/Launcher.swift"}
    end
  end

  test "--check-defaults prints the JSON shape DefaultHandler.parse_status/1 expects", %{
    binary: binary
  } do
    {output, 0} = System.cmd(binary, ["--check-defaults"], env: CommandEnvironment.scrubbed())

    assert %{supported: true, torrent: t, magnet: m} = DefaultHandler.parse_status(output)
    assert is_boolean(t)
    assert is_boolean(m)
  end

  test "registering the magnet: scheme is immediately visible to a fresh process", %{
    binary: binary
  } do
    # This is the regression this file exists for: `registerAsDefault()` used
    # to return before LaunchServices had persisted the change, so a
    # `--check-defaults` run in a brand new process (exactly what
    # `DefaultHandler.status/0` does from Elixir) could still read the old
    # handler. `registerAsDefault()` now polls its own result before
    # returning — see `awaitStatus()` in Launcher.swift. `magnet:` is a
    # URL scheme, not a content type, so it isn't subject to the
    # multi-claimant contention the shared torrent UTI has (see the test
    # below) — it isolates the timing fix on its own.
    assert {_, 0} =
             System.cmd(binary, ["--register-defaults"], env: CommandEnvironment.scrubbed())

    {output, 0} = System.cmd(binary, ["--check-defaults"], env: CommandEnvironment.scrubbed())
    status = DefaultHandler.parse_status(output)

    assert status.magnet == true
  end

  test "registering wins the shared org.bittorrent.torrent UTI too", %{binary: binary} do
    # `org.bittorrent.torrent` is the UTI real `.torrent` files carry — see
    # `isDefaultForTorrentFiles` in Launcher.swift — and, unlike our own
    # exported type, other installed torrent clients claim it too. Waiting for
    # this out here (with a real sleep, in a retry loop) is exactly what
    # `.claude/TESTING.md` rules out — "do not use Process.sleep ... or busy
    # polling ... as a correctness assertion." The waiting already happens in
    # production code (`awaitStatus()` in Launcher.swift, invoked by
    # `--register-defaults` itself); this test's job is a single, honest check
    # of its result, not to paper over a miss by polling around it.
    assert {_, 0} =
             System.cmd(binary, ["--register-defaults"], env: CommandEnvironment.scrubbed())

    {output, 0} = System.cmd(binary, ["--check-defaults"], env: CommandEnvironment.scrubbed())

    assert DefaultHandler.parse_status(output).torrent, """
    org.bittorrent.torrent did not become our default after registering.

    If this reproduces on a clean CI runner (not just a dev machine with other
    torrent clients installed and a lot of prior manual LaunchServices churn),
    it points at a real regression — check:
      - priv/macos/Info.plist: UTImportedTypeDeclarations for org.bittorrent.torrent,
        and that com.elixirtorrent.webui.torrent's UTTypeConformsTo lists it
      - `lsregister -dump | grep -B8 'identifier:.*com.elixirtorrent.webui$'` for
        more than one registered path under our bundle id (stale dist/ or
        dmg-staging/ copies make the target ambiguous to LaunchServices)
      - awaitStatus()'s budget in registerAsDefault() may need raising
    """
  end

  test "--await-default-status reports convergence for real, not just a snapshot", %{
    binary: binary
  } do
    # This is what DefaultHandler.await_default/0 shells out to instead of
    # Elixir re-polling `--check-defaults` on a timer. Register first so
    # there is something to converge on, then confirm the *standalone*
    # subcommand — a fresh process, same as Elixir would spawn — actually
    # blocks until it is true rather than printing a single snapshot.
    assert {_, 0} =
             System.cmd(binary, ["--register-defaults"], env: CommandEnvironment.scrubbed())

    {output, 0} =
      System.cmd(binary, ["--await-default-status"], env: CommandEnvironment.scrubbed())

    assert DefaultHandler.parse_status(output) == %{supported: true, torrent: true, magnet: true}
  end

  test "DefaultHandler.await_default/2 round-trips through the real launcher", %{binary: binary} do
    env = fn
      "ELIXIR_TORRENT_LAUNCHER" -> binary
      _ -> nil
    end

    assert {_, 0} =
             System.cmd(binary, ["--register-defaults"], env: CommandEnvironment.scrubbed())

    status = DefaultHandler.await_default({:unix, :darwin}, env)

    assert status == %{supported: true, torrent: true, magnet: true}
  end

  defp compile_launcher! do
    binary =
      Path.join(
        System.tmp_dir!(),
        "elixir_torrent_launcher_test_#{System.unique_integer([:positive])}"
      )

    {_, 0} =
      System.cmd(
        "swiftc",
        [
          "priv/macos/Launcher.swift",
          "-o",
          binary,
          "-framework",
          "AppKit",
          "-swift-version",
          "6",
          "-O"
        ],
        env: CommandEnvironment.scrubbed()
      )

    binary
  end
end
