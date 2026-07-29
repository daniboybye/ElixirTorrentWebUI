defmodule ElixirTorrentWebUI.EngineMediaTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.Engine

  test "previews only complete browser-compatible images within the inline limit" do
    assert Engine.previewable_image?(file("cover.jpg", complete?: true, length: 1_024))
    refute Engine.previewable_image?(file("cover.jpg", complete?: false, length: 1_024))
    refute Engine.previewable_image?(file("cover.heic", complete?: true, length: 1_024))

    refute Engine.previewable_image?(file("cover.jpg", complete?: true, length: 51 * 1024 * 1024))
  end

  test "allows complete image formats to open in the OS even without browser preview" do
    assert Engine.openable_image?(file("capture.heic", complete?: true, length: 1_024))
    refute Engine.openable_image?(file("capture.heic", complete?: false, length: 1_024))
    refute Engine.openable_image?(file("notes.txt", complete?: true, length: 1_024))
  end

  defp file(name, opts) do
    complete? = Keyword.fetch!(opts, :complete?)
    length = Keyword.fetch!(opts, :length)

    %Engine.FileRow{
      index: 0,
      path: "album/#{name}",
      name: name,
      length: length,
      downloaded: if(complete?, do: length, else: 0),
      progress: if(complete?, do: 100.0, else: 0.0),
      complete?: complete?
    }
  end
end
