defmodule ElixirTorrentWebUIWeb.MagnetControllerTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  test "rejects a missing magnet", %{conn: conn} do
    conn = post(conn, ~p"/api/magnets", %{})

    assert %{"error" => "missing magnet"} = json_response(conn, 400)
  end

  test "rejects a malformed magnet before queueing work", %{conn: conn} do
    conn = post(conn, ~p"/api/magnets", %{"magnet" => "not-a-magnet"})

    assert %{"error" => "invalid magnet"} = json_response(conn, 422)
  end

  test "Engine validates canonical magnet links" do
    assert ElixirTorrentWebUI.Engine.valid_magnet?(
             "magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567"
           )

    refute ElixirTorrentWebUI.Engine.valid_magnet?("https://example.com/file.torrent")
  end
end
