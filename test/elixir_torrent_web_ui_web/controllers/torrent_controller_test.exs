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
end
