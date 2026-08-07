defmodule ElixirTorrentWebUIWeb.TorrentsLiveTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    :ok = ElixirTorrentWebUI.UiState.put_locale("en")
    {:ok, conn: build_conn()}
  end

  test "renders lifetime totals and current aggregate rates in the top bar", %{conn: conn} do
    html =
      conn
      |> get(~p"/")
      |> html_response(200)

    assert html =~ ~s(id="aggregate-stats")
    assert html =~ "Transfer statistics"
    assert html =~ "Downloaded"
    assert html =~ "Uploaded"
    assert html =~ "Speed"
  end

  test "keeps executable JavaScript in external assets for CSP", %{conn: conn} do
    html =
      conn
      |> get(~p"/")
      |> html_response(200)

    assert html =~ ~s(src="/assets/js/app.js")
    refute html =~ ~r/<script(?![^>]*\bsrc=)[^>]*>\s*\S/s
  end

  test "applies the pushed theme through the LiveView hook payload" do
    source = File.read!("assets/js/app.js")

    # push_event/3 delivers "set-theme" to the hook callback with the payload as
    # its argument. The window listener that used to mirror it read
    # event.target.dataset.phxTheme, which throws because event.target is window,
    # so server-driven theme sync silently never applied. Keep the hook as the
    # single consumer, and keep the toggle going through the server, which
    # answers the "toggle_theme" click with its own "set-theme" push.
    assert source =~ ~s|handleEvent("set-theme"|
    refute source =~ "phx:set-theme"
    refute source =~ "phx:toggle-theme"
    refute source =~ "dataset.phxTheme"
  end

  test "validates pasted magnet links before starting ingest", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_click(view, "add_magnet", %{"magnet" => ""}) =~
             "Paste a magnet link"

    assert render_click(view, "add_magnet", %{"magnet" => "not-a-magnet"}) =~
             "Not a valid magnet link"

    assert render_click(view, "add_magnet", %{"error" => "clipboard"}) =~
             "Could not read clipboard"
  end

  test "resets lifetime statistics from Settings", %{conn: conn} do
    original = :sys.get_state(ElixirTorrentWebUI.StatsStore)

    on_exit(fn ->
      :sys.replace_state(ElixirTorrentWebUI.StatsStore, fn _state -> original end)
      ElixirTorrentWebUI.StatsStore.persist_state()
    end)

    :sys.replace_state(ElixirTorrentWebUI.StatsStore, fn state ->
      %{state | total_downloaded: 4_096, total_uploaded: 2_048, dirty?: true}
    end)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "4 KB"
    assert html =~ "2 KB"

    view
    |> element("#open-settings")
    |> render_click()

    assert has_element?(view, "#settings-reset-statistics", "Reset Statistics")

    html =
      view
      |> element("#settings-reset-statistics")
      |> render_click()

    assert html =~ "Transfer statistics reset"
    assert ElixirTorrentWebUI.StatsStore.get() == %{total_downloaded: 0, total_uploaded: 0}
  end

  test "renders lazy image thumbnails and an OS-open fallback" do
    torrent_id = String.duplicate("A", 40)

    preview =
      render_component(&ElixirTorrentWebUIWeb.TorrentsLive.torrent_file_leading/1,
        file: file_row("cover.jpg"),
        torrent_id: torrent_id
      )

    assert preview =~ ~s(id="torrent-file-image-#{torrent_id}-7")
    assert preview =~ ~s(src="/media/#{torrent_id}/7/preview")
    assert preview =~ ~s(loading="lazy")
    assert preview =~ ~s(decoding="async")

    fallback =
      render_component(&ElixirTorrentWebUIWeb.TorrentsLive.torrent_file_leading/1,
        file: file_row("capture.heic"),
        torrent_id: torrent_id
      )

    assert fallback =~ "hero-photo"
    refute fallback =~ "<img"
  end

  test "reports image open failures without accepting arbitrary paths", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      render_click(view, "open_image", %{
        "torrent_id" => String.duplicate("0", 40),
        "file_index" => "0"
      })

    assert html =~ "Could not open this image"
  end

  test "locale route remounts UI in Bulgarian without manual reload", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Settings"
    assert html_response(conn, 200) =~ "Add torrent"

    conn = get(conn, ~p"/locale/bg")
    assert redirected_to(conn) == ~p"/"
    conn = get(recycle(conn), redirected_to(conn))

    html = html_response(conn, 200)

    assert html =~ "Настройки"
    assert html =~ "Добави торент"
    assert html =~ "Версия"
    refute html =~ ~r/>Settings</
  end

  test "locale route can switch back to English", %{conn: conn} do
    :ok = ElixirTorrentWebUI.UiState.put_locale("bg")

    conn = get(conn, ~p"/locale/bg")
    assert redirected_to(conn) == ~p"/"
    conn = get(recycle(conn), redirected_to(conn))

    assert html_response(conn, 200) =~ "Настройки"

    conn = get(conn, ~p"/locale/en")
    assert redirected_to(conn) == ~p"/"
    conn = get(recycle(conn), redirected_to(conn))

    html = html_response(conn, 200)

    assert html =~ "Settings"
    assert html =~ "Add torrent"
    refute html =~ "Настройки"
  end

  test "icon-only top-bar buttons carry a tooltip and share one size", %{conn: conn} do
    html =
      conn
      |> get(~p"/")
      |> html_response(200)

    for tip <- ["Toggle theme", "Settings", "Report a problem"] do
      assert html =~ ~s(data-tip="#{tip}")
    end

    # Theme / Settings / Report are icon-only: their label lives in the tooltip
    # and the accessible name, never as visible text next to the icon.
    refute html =~ ~r/>\s*Report a problem\s*</
    refute html =~ ~r/>\s*Settings\s*</

    for id <- ["toggle-theme", "open-settings", "open-report"] do
      assert html =~ ~r/id="#{id}"[^>]*class="[^"]*\bsize-9\b/s
    end
  end

  test "Paste magnet & Go and Add torrent carry their own visible label, not a tooltip",
       %{conn: conn} do
    html =
      conn
      |> get(~p"/")
      |> html_response(200)

    refute html =~ ~s(data-tip="Paste magnet &amp; Go")
    refute html =~ ~s(data-tip="Add torrent")
    assert html =~ ~s(id="paste-magnet-go")
    assert html =~ "Paste magnet &amp; Go"
    assert html =~ "Add torrent"
  end

  test "dismissing the default-handler prompt keeps the page alive", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(view, "dismiss_default_prompt", %{})

    assert html =~ ~s(id="torrents-live")
    refute html =~ ~s(id="default-handler-prompt")
  end

  test "clicking Set as default without a packaged launcher surfaces an error, not a crash",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(view, "request_default_handler", %{})

    assert html =~ "only available in the packaged app" or
             html =~ "only available on macOS and Windows"

    assert Process.alive?(view.pid)
  end

  defp file_row(name) do
    %ElixirTorrentWebUI.Engine.FileRow{
      index: 7,
      path: "album/#{name}",
      name: name,
      length: 1_024,
      downloaded: 1_024,
      progress: 100.0,
      complete?: true
    }
  end
end
