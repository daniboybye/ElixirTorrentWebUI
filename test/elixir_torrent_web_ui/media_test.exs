defmodule ElixirTorrentWebUI.MediaTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.Media

  test "classifies browser-preview and OS-only image formats" do
    assert Media.image?("PHOTO.JPG")
    assert Media.browser_image?("PHOTO.JPG")
    assert Media.image?("capture.heic")
    refute Media.browser_image?("capture.heic")
    refute Media.image?("archive.zip")
  end

  test "returns allow-listed image content types" do
    assert Media.image_content_type("photo.jpeg") == {:ok, "image/jpeg"}
    assert Media.image_content_type("scan.tiff") == {:ok, "image/tiff"}
    assert Media.image_content_type("movie.mp4") == {:error, :unsupported}
  end
end
