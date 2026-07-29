defmodule ElixirTorrentWebUI.PathGuardTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.PathGuard

  test "joins a nested torrent path under its download root" do
    base = Path.join(System.tmp_dir!(), "path-guard-root")

    assert PathGuard.safe_join(base, "album/cover.jpg") ==
             {:ok, Path.join(base, "album/cover.jpg") |> Path.expand()}
  end

  test "rejects traversal and absolute paths on every host" do
    base = Path.join(System.tmp_dir!(), "path-guard-root")

    for path <- [
          "../secret.jpg",
          "album/../../secret.jpg",
          "/etc/passwd",
          "C:\\Users\\name\\secret.jpg",
          "\\\\server\\share\\secret.jpg",
          "//server/share/secret.jpg",
          "cover.jpg" <> <<0>>
        ] do
      assert PathGuard.safe_join(base, path) == {:error, :invalid_path}
    end
  end
end
