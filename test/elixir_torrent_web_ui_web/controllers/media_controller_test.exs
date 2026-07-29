defmodule ElixirTorrentWebUIWeb.MediaControllerTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  defmodule ResolverStub do
    def resolve_image_preview(_torrent_id, _index) do
      {:ok,
       %{
         name: "cover.png",
         path: Application.fetch_env!(:elixir_torrent_web_ui, :media_test_path),
         content_type: "image/png"
       }}
    end
  end

  test "image preview route rejects malformed torrent ids", %{conn: conn} do
    conn = get(conn, ~p"/media/not-a-hash/0/preview")

    assert response(conn, 404) == "Not found"
  end

  test "image preview route rejects malformed file indexes", %{conn: conn} do
    torrent_id = String.duplicate("0", 40)
    conn = get(conn, ~p"/media/#{torrent_id}/not-an-index/preview")

    assert response(conn, 404) == "Not found"
  end

  test "image preview route returns not found for an inactive torrent", %{conn: conn} do
    torrent_id = String.duplicate("0", 40)
    conn = get(conn, ~p"/media/#{torrent_id}/0/preview")

    assert response(conn, 404) == "Not found"
  end

  test "serves a resolved image with private cache and nosniff headers", %{conn: conn} do
    {body, _path} = configure_preview_fixture()

    torrent_id = String.duplicate("A", 40)
    conn = get(conn, ~p"/media/#{torrent_id}/7/preview")

    assert response(conn, 200) == body
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "serves valid byte ranges for preview images", %{conn: conn} do
    {body, _path} = configure_preview_fixture()
    torrent_id = String.duplicate("A", 40)

    conn =
      conn
      |> put_req_header("range", "bytes=2-4")
      |> get(~p"/media/#{torrent_id}/7/preview")

    assert response(conn, 206) == binary_part(body, 2, 3)
    assert get_resp_header(conn, "content-range") == ["bytes 2-4/8"]
    assert get_resp_header(conn, "content-length") == ["3"]
  end

  test "rejects malformed and out-of-bounds byte ranges" do
    configure_preview_fixture()
    torrent_id = String.duplicate("A", 40)

    for range <- ["bytes=wat", "bytes=99-100", "items=0-1"] do
      response =
        build_conn()
        |> put_req_header("range", range)
        |> get(~p"/media/#{torrent_id}/7/preview")

      assert response(response, 416) == "Invalid range"
    end
  end

  defp configure_preview_fixture do
    path = Path.join(System.tmp_dir!(), "media-preview-#{System.unique_integer([:positive])}.png")
    body = <<137, 80, 78, 71, 13, 10, 26, 10>>
    File.write!(path, body)

    previous_resolver = Application.get_env(:elixir_torrent_web_ui, :media_resolver)
    previous_path = Application.get_env(:elixir_torrent_web_ui, :media_test_path)

    Application.put_env(:elixir_torrent_web_ui, :media_resolver, ResolverStub)
    Application.put_env(:elixir_torrent_web_ui, :media_test_path, path)

    on_exit(fn ->
      restore_env(:media_resolver, previous_resolver)
      restore_env(:media_test_path, previous_path)
      File.rm(path)
    end)

    {body, path}
  end

  defp restore_env(key, nil), do: Application.delete_env(:elixir_torrent_web_ui, key)
  defp restore_env(key, value), do: Application.put_env(:elixir_torrent_web_ui, key, value)
end
