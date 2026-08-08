defmodule ElixirTorrentWebUI.MacOS.LauncherIntegrationTest do
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.{CommandEnvironment, DefaultHandler}

  # Compiles priv/macos/Launcher.swift for real and runs it, so the one thing
  # no source-level assertion can cover stays honest: that the bytes the real
  # binary prints are the bytes `DefaultHandler.parse_status/1` can read. Every
  # check here is read-only.
  #
  # This module deliberately does NOT test that registering actually takes the
  # default handler over. `LSSetDefaultRoleHandlerForContentType` asks the user
  # to confirm in a modal dialog whenever another app currently owns the type
  # (the same prompt priv/scripts/macos/set-utorrent-web-default.sh documents),
  # and a headless `mix test` has nobody to click it — so on any machine with
  # another torrent client installed, such a test fails for a reason that is
  # not a defect. That is macOS asking for user consent, and working around it
  # is not something this suite should try to do.
  #
  # The behaviour those tests used to reach for is covered without touching the
  # LaunchServices database at all:
  #
  #   * that we call the expected LaunchServices APIs (both content types plus
  #     the magnet scheme), that the CLI verbs exist, and that the await
  #     subcommand really blocks — test/macos/launcher_test.exs, against the
  #     Swift source
  #   * command construction per platform and status parsing —
  #     test/elixir_torrent_web_ui/default_handler_test.exs
  #   * the end-to-end "banner clears when the launcher reports convergence"
  #     flow, driven through a stub launcher on ELIXIR_TORRENT_LAUNCHER —
  #     test/macos/default_handler_prompt_flow_test.exs
  #
  # Still tagged :macos_integration (excluded by default, see
  # test/test_helper.exs) because it shells out to `swiftc`, which needs Xcode.
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
      {:skip, "macOS-only: compiles and runs priv/macos/Launcher.swift"}
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
