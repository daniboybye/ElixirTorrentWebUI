defmodule ElixirTorrentWebUI.Media do
  @moduledoc false

  @video_extensions ~w(
    mp4 m4v webm ogv mov mkv avi wmv flv mpg mpeg mp2t ts
  )

  @extension_mime %{
    "mp4" => "video/mp4",
    "m4v" => "video/mp4",
    "webm" => "video/webm",
    "ogv" => "video/ogg",
    "mov" => "video/quicktime",
    "mkv" => "video/x-matroska",
    "avi" => "video/x-msvideo",
    "wmv" => "video/x-ms-wmv",
    "flv" => "video/x-flv",
    "mpg" => "video/mpeg",
    "mpeg" => "video/mpeg",
    "mp2t" => "video/mp2t",
    "ts" => "video/mp2t"
  }

  @spec video?(Path.t()) :: boolean()
  def video?(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
    |> then(&(&1 in @video_extensions))
  end

  @spec content_type(Path.t()) :: {:ok, String.t()} | {:error, :unsupported}
  def content_type(path) when is_binary(path) do
    case Path.extname(path) |> String.trim_leading(".") |> String.downcase() do
      ext when is_binary(ext) ->
        case Map.fetch(@extension_mime, ext) do
          {:ok, mime} -> {:ok, mime}
          :error -> {:error, :unsupported}
        end
    end
  end
end
