defmodule ElixirTorrentWebUIWeb.MediaController do
  use ElixirTorrentWebUIWeb, :controller

  alias ElixirTorrentWebUI.Engine

  def show(conn, %{"torrent_id" => torrent_id, "file_index" => file_index}) do
    with {index, ""} <- Integer.parse(file_index),
         {:ok, %{path: path, content_type: content_type}} <-
           Engine.resolve_video(torrent_id, index) do
      serve_path(conn, path, content_type)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  def preview(conn, %{"torrent_id" => torrent_id, "file_index" => file_index}) do
    with {index, ""} <- Integer.parse(file_index),
         {:ok, %{path: path, content_type: content_type}} <-
           media_resolver().resolve_image_preview(torrent_id, index) do
      conn
      |> put_resp_header("cache-control", "private, max-age=60")
      |> serve_path(path, content_type)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> text("Not found")
    end
  end

  defp media_resolver do
    Application.get_env(:elixir_torrent_web_ui, :media_resolver, Engine)
  end

  # The resolver derives this path server-side from torrent id/file index and
  # validates it with PathGuard.safe_join/2 before this controller receives it.
  # sobelow_skip ["Traversal.SendFile"]
  defp serve_path(conn, path, content_type) do
    size = File.stat!(path).size

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("content-disposition", content_disposition(path))
      |> put_resp_header("x-content-type-options", "nosniff")

    case get_req_header(conn, "range") do
      [range | _] ->
        serve_range(conn, path, size, range)

      _ ->
        conn
        |> put_resp_header("content-length", Integer.to_string(size))
        |> send_file(200, path)
    end
  end

  # serve_path/3 is the only caller, so ranged responses retain the same
  # server-side path resolution and traversal guard.
  # sobelow_skip ["Traversal.SendFile"]
  defp serve_range(conn, path, size, "bytes=" <> spec) do
    case parse_range(spec, size) do
      {:ok, start, end_byte} ->
        length = end_byte - start + 1

        conn
        |> put_resp_header("content-range", "bytes #{start}-#{end_byte}/#{size}")
        |> put_resp_header("content-length", Integer.to_string(length))
        |> send_file(206, path, start, length)

      :error ->
        invalid_range(conn)
    end
  end

  defp serve_range(conn, _path, _size, _range), do: invalid_range(conn)

  defp invalid_range(conn) do
    conn
    |> put_status(:requested_range_not_satisfiable)
    |> text("Invalid range")
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      [start_str, ""] ->
        with {start, ""} <- Integer.parse(start_str),
             true <- start >= 0 and start < size do
          {:ok, start, size - 1}
        else
          _ -> :error
        end

      [start_str, end_str] ->
        with {start, ""} <- Integer.parse(start_str),
             {end_byte, ""} <- Integer.parse(end_str),
             true <- start >= 0 and start < size and end_byte >= start do
          {:ok, start, min(end_byte, size - 1)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp content_disposition(path) do
    filename = Path.basename(path) |> String.replace("\"", "")
    ~s(inline; filename="#{filename}")
  end
end
