defmodule ElixirTorrentWebUIWeb.MacOS.DefaultHandlerPromptFlowTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # These tests point ELIXIR_TORRENT_LAUNCHER at a throwaway fake launcher
  # script and let the LiveView's own `start_async/3` call run for real
  # against it — `render_async/1` waits for that task to resolve, so there is
  # no manual message-driving and no real sleep anywhere here. They need to
  # run in isolation from anything else that mounts TorrentsLive (mount/3
  # reads the real env var too). Tagged and excluded by default alongside
  # MacOS.LauncherIntegrationTest; see test/test_helper.exs.
  @moduletag :macos_integration
  @moduletag timeout: 60_000

  setup do
    if match?({:unix, :darwin}, :os.type()) do
      :ok = ElixirTorrentWebUI.UiState.put_locale("en")
      {:ok, conn: build_conn()}
    else
      {:skip, "macOS-only: exercises DefaultHandler.request_default/0 against a real launcher"}
    end
  end

  test "the banner clears itself once the launcher notifies us, without a page reload", %{
    conn: conn
  } do
    # `--check-defaults` always reports "not yet" here, standing in for the
    # click-time synchronous check missing the flip — exactly the case that
    # hands off to the background await. `--await-default-status` is what
    # that background task calls, and it reports the flip having happened.
    launcher = fake_launcher(await_converges?: true)
    System.put_env("ELIXIR_TORRENT_LAUNCHER", launcher)
    on_exit(fn -> System.delete_env("ELIXIR_TORRENT_LAUNCHER") end)

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(view, "request_default_handler", %{})
    assert html =~ ~s(id="default-handler-prompt")

    html = render_async(view)
    refute html =~ ~s(id="default-handler-prompt")
  end

  test "it gives up quietly if the launcher's own wait times out too", %{conn: conn} do
    # Simulates Windows before the user clicks through Settings, or macOS
    # LaunchServices staying stuck past the launcher's own budget: the
    # background task resolves, but still to "not converged."
    launcher = fake_launcher(await_converges?: false)
    System.put_env("ELIXIR_TORRENT_LAUNCHER", launcher)
    on_exit(fn -> System.delete_env("ELIXIR_TORRENT_LAUNCHER") end)

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(view, "request_default_handler", %{})
    assert html =~ ~s(id="default-handler-prompt")

    html = render_async(view)
    assert html =~ ~s(id="default-handler-prompt")
    assert Process.alive?(view.pid)
  end

  defp fake_launcher(await_converges?: await_converges?) do
    script_path =
      Path.join(System.tmp_dir!(), "fake_launcher_#{System.unique_integer([:positive])}.sh")

    await_payload =
      if await_converges? do
        ~s({"torrent":true,"magnet":true})
      else
        ~s({"torrent":false,"magnet":false})
      end

    script = """
    #!/bin/sh
    set -eu
    case "$1" in
      --register-defaults)
        exit 0
        ;;
      --check-defaults)
        echo '{"torrent":false,"magnet":false}'
        ;;
      --await-default-status)
        echo '#{await_payload}'
        ;;
      *)
        exit 1
        ;;
    esac
    """

    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)

    on_exit(fn -> File.rm(script_path) end)

    script_path
  end
end
