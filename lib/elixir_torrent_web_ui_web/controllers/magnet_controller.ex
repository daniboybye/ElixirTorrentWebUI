defmodule ElixirTorrentWebUIWeb.MagnetController do
  use ElixirTorrentWebUIWeb, :controller

  require Logger

  alias ElixirTorrentWebUI.{Engine, MagnetIngest}

  def create(conn, %{"magnet" => magnet}) when is_binary(magnet) do
    magnet = String.trim(magnet)

    cond do
      magnet == "" ->
        bad_request(conn, "missing magnet")

      not Engine.valid_magnet?(magnet) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid magnet"})

      true ->
        Logger.debug("MagnetController: accepted magnet")
        :ok = MagnetIngest.submit(magnet)

        conn
        |> put_status(:accepted)
        |> json(%{status: "queued"})
    end
  end

  def create(conn, _params), do: bad_request(conn, "missing magnet")

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end
end
