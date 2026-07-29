defmodule ElixirTorrentWebUI.OsIntegrationTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.OsIntegration

  test "uses the macOS default application without invoking a shell" do
    path = "/tmp/photo with spaces.jpg"

    assert OsIntegration.open_file_command({:unix, :darwin}, path) ==
             {:ok, "open", [path]}
  end

  test "reports Windows as pending instead of pretending parity" do
    assert OsIntegration.open_file_command({:win32, :nt}, "C:\\photo.jpg") ==
             {:error, :unsupported_platform}
  end
end
