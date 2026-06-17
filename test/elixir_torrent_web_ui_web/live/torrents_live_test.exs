defmodule ElixirTorrentWebUIWeb.TorrentsLiveTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  setup do
    :ok = ElixirTorrentWebUI.UiState.put_locale("en")
    {:ok, conn: build_conn()}
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
end
