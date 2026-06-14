defmodule ElixirTorrentWebUIWeb.TorrentController do
  use ElixirTorrentWebUIWeb, :controller

  alias ElixirTorrentWebUI.TorrentIngest

  def create(conn, %{"path" => path}) when is_binary(path) do
    path = Path.expand(path)

    if torrent_file?(path) do
      :ok = TorrentIngest.submit(path)

      conn
      |> put_status(:accepted)
      |> json(%{status: "queued"})
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "invalid torrent path"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing path"})
  end

  @spec torrent_file?(Path.t()) :: boolean()
  defp torrent_file?(path) do
    File.regular?(path) and String.ends_with?(String.downcase(path), ".torrent")
  end
end
