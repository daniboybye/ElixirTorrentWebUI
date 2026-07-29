defmodule ElixirTorrentWebUIWeb.TorrentControllerTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  test "returns the stable collection consumed by the macOS Dock menu", %{conn: conn} do
    conn = get(conn, ~p"/api/torrents")

    assert %{"torrents" => torrents} = json_response(conn, 200)
    assert is_list(torrents)

    Enum.each(torrents, fn torrent ->
      assert Map.keys(torrent) |> Enum.sort() ==
               ~w(down_kbps name progress status up_kbps)
    end)
  end

  test "rejects missing and invalid torrent paths", %{conn: conn} do
    missing = post(conn, ~p"/api/torrents", %{})
    assert %{"error" => "missing path"} = json_response(missing, 400)

    invalid = post(build_conn(), ~p"/api/torrents", %{"path" => "/tmp/not-a-torrent.txt"})
    assert %{"error" => "invalid torrent path"} = json_response(invalid, 400)
  end
end
