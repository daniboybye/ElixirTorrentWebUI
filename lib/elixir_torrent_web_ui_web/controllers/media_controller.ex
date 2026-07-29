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

  defp serve_range(conn, path, size, "bytes=" <> spec) do
    {start, end_byte} = parse_range(spec, size)
    length = end_byte - start + 1

    conn
    |> put_status(206)
    |> put_resp_header("content-range", "bytes #{start}-#{end_byte}/#{size}")
    |> put_resp_header("content-length", Integer.to_string(length))
    |> send_file(206, path, start, length)
  end

  defp serve_range(conn, _path, _size, _range) do
    conn
    |> put_status(:requested_range_not_satisfiable)
    |> text("Invalid range")
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      [start_str, ""] ->
        start = String.to_integer(start_str)
        {start, size - 1}

      [start_str, end_str] ->
        {String.to_integer(start_str), String.to_integer(end_str)}

      _ ->
        {0, size - 1}
    end
  end

  defp content_disposition(path) do
    filename = Path.basename(path) |> String.replace("\"", "")
    ~s(inline; filename="#{filename}")
  end
end
