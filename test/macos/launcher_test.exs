defmodule ElixirTorrentWebUI.MacOS.LauncherTest do
  use ExUnit.Case, async: true

  # The Swift launcher answers `--check-defaults`, which `DefaultHandler`
  # parses. There is no Swift test harness in this project, so — as with the
  # `assets/js/app.js` assertions in the LiveView tests — the invariants that
  # are easy to regress are pinned against the source itself.

  @src_dir "priv/macos/src"
  @default_handler_coordinator Path.join(@src_dir, "DefaultHandlerCoordinator.swift")
  @launcher_cli Path.join(@src_dir, "LauncherCLI.swift")
  @app_delegate Path.join(@src_dir, "AppDelegate.swift")

  setup do
    {:ok,
     coordinator_source: read_source(@default_handler_coordinator),
     cli_source: read_source(@launcher_cli),
     app_delegate_source: read_source(@app_delegate)}
  end

  test "the .torrent status never accepts our own exported UTI as proof", %{
    coordinator_source: source
  } do
    # `com.elixirtorrent.webui.torrent` is declared by this bundle alone, so it
    # resolves back to us the moment we are registered. OR-ing it into the
    # check reported "already the default" while another client owned every
    # real `.torrent` file, which hid the Settings banner.
    body = function_body(source, ~r/func currentStatus\(\) -> Status \{(.+?)\n    \}/s)

    refute body =~ "handlerForContentType(torrentType)"
    assert body =~ "torrent: isDefaultForTorrentFiles(target)"
  end

  test "the shared UTI decides, with the exported one only as a fallback", %{
    coordinator_source: source
  } do
    body =
      function_body(
        source,
        ~r/func isDefaultForTorrentFiles\(_ target: String\) -> Bool \{(.+?)\n    \}/s
      )

    {legacy_at, _} = :binary.match(body, "(legacyTorrentType)")
    {exported_at, _} = :binary.match(body, "(torrentType)")

    assert legacy_at < exported_at,
           "org.bittorrent.torrent must be consulted before the exported type"
  end

  test "registering still claims both content types and the magnet scheme", %{
    coordinator_source: source
  } do
    assert source =~ "LSSetDefaultRoleHandlerForContentType(\n            torrentType as CFString"

    assert source =~
             "LSSetDefaultRoleHandlerForContentType(\n            legacyTorrentType as CFString"

    assert source =~ "LSSetDefaultHandlerForURLScheme(\n            magnetScheme as CFString"
  end

  test "the launcher still exposes the CLI DefaultHandler shells out to", %{cli_source: source} do
    assert source =~ ~s(case "--check-defaults":)
    assert source =~ ~s(case "--register-defaults":)
    assert source =~ ~s(case "--await-default-status":)
  end

  test "the status payload shape matches what DefaultHandler.parse_status/1 expects", %{
    coordinator_source: source
  } do
    assert source =~ ~s({\\"torrent\\":)
    assert source =~ ~s(\\"magnet\\":)
  end

  test "await-default-status blocks in this process instead of a fixed poll interval", %{
    cli_source: source
  } do
    # This is the notification path DefaultHandler.await_default/0 shells
    # out to — it must loop on its own (inside this one process) until the
    # OS reflects the change, not just check once, or Elixir would be back
    # to guessing a fixed backoff.
    body =
      function_body(
        source,
        ~r/case "--await-default-status":(.+?)\n\n        default:/s
      )

    assert body =~ "DefaultHandlerCoordinator.awaitStatus("
  end

  test "registering shares its wait loop with the standalone await subcommand", %{
    coordinator_source: source
  } do
    body = function_body(source, ~r/func registerAsDefault\(\) -> Bool \{(.+?)\n    \}/s)

    assert body =~ "awaitStatus("
    refute body =~ "awaitConvergence("
  end

  test "there is no boot-time alert nagging about the default handler", %{
    app_delegate_source: source
  } do
    # The in-page banner (torrents_live.ex's default_handler_prompt/1) is the
    # only "make us default" prompt now — it is what the user sees on every
    # open, including in development, and it does not require macOS's
    # first-launch permission dance around a modal NSAlert. A native alert on
    # top of that was redundant and, worse, stole window focus on launch.
    refute source =~ "maybePromptForDefaultHandler"
    refute source =~ "your default torrent app?"
    refute source =~ "DefaultHandlerPromptDismissed"

    body = function_body(source, ~r/private func bootstrap\(\) async \{(.+?)\n    \}/s)
    refute body =~ "Prompt"
  end

  # What these tests pin is the Swift source's content, never its line endings.
  # A Windows checkout hands back CRLF, which broke every pattern spanning a
  # line break — the repository normalises to LF via .gitattributes, and
  # reading through here keeps the assertions true of any working tree.
  defp read_source(path) do
    path
    |> File.read!()
    |> String.replace("\r\n", "\n")
  end

  defp function_body(source, regex) do
    [_, body] = Regex.run(regex, source)
    body
  end
end
