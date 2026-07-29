defmodule ElixirTorrentWebUI.Media do
  @moduledoc false

  @video_extensions ~w(
    mp4 m4v webm ogv mov mkv avi wmv flv mpg mpeg mp2t ts
  )

  @browser_image_extensions ~w(jpg jpeg png gif webp avif bmp)
  @image_extensions @browser_image_extensions ++ ~w(heic heif tif tiff)

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
    "ts" => "video/mp2t",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "png" => "image/png",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "avif" => "image/avif",
    "bmp" => "image/bmp",
    "heic" => "image/heic",
    "heif" => "image/heif",
    "tif" => "image/tiff",
    "tiff" => "image/tiff"
  }

  @spec video?(Path.t()) :: boolean()
  def video?(path) when is_binary(path) do
    extension(path) in @video_extensions
  end

  @spec image?(Path.t()) :: boolean()
  def image?(path) when is_binary(path), do: extension(path) in @image_extensions

  @spec browser_image?(Path.t()) :: boolean()
  def browser_image?(path) when is_binary(path),
    do: extension(path) in @browser_image_extensions

  @spec image_content_type(Path.t()) :: {:ok, String.t()} | {:error, :unsupported}
  def image_content_type(path) when is_binary(path) do
    if image?(path), do: content_type(path), else: {:error, :unsupported}
  end

  @spec content_type(Path.t()) :: {:ok, String.t()} | {:error, :unsupported}
  def content_type(path) when is_binary(path) do
    case extension(path) do
      ext when is_binary(ext) ->
        case Map.fetch(@extension_mime, ext) do
          {:ok, mime} -> {:ok, mime}
          :error -> {:error, :unsupported}
        end
    end
  end

  defp extension(path) do
    path
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
  end
end
