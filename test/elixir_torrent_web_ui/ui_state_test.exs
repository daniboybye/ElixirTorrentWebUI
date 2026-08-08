defmodule ElixirTorrentWebUI.UiStateTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.UiState

  describe "default_download_folder/2" do
    test "resolves USERPROFILE\\Downloads on Windows" do
      env = %{"USERPROFILE" => "C:\\Users\\Daniel"}

      assert UiState.default_download_folder({:win32, :nt}, &Map.get(env, &1)) ==
               Path.expand("C:\\Users\\Daniel/Downloads")
    end

    test "falls back to HOMEDRIVE + HOMEPATH when USERPROFILE is missing" do
      env = %{"HOMEDRIVE" => "D:", "HOMEPATH" => "\\Users\\Daniel"}

      assert UiState.default_download_folder({:win32, :nt}, &Map.get(env, &1)) ==
               Path.expand("D:\\Users\\Daniel/Downloads")
    end

    test "uses cwd + Downloads when no Windows env is available" do
      cwd = File.cwd!()

      assert UiState.default_download_folder({:win32, :nt}, fn _ -> nil end) ==
               Path.expand(Path.join(cwd, "Downloads"))
    end

    test "resolves $HOME/Downloads on Unix hosts" do
      env = %{"HOME" => "/Users/daniel"}

      assert UiState.default_download_folder({:unix, :darwin}, &Map.get(env, &1)) ==
               "/Users/daniel/Downloads"
    end

    test "raises on Unix hosts when HOME is not set" do
      assert_raise RuntimeError, ~r/HOME is not set/, fn ->
        UiState.default_download_folder({:unix, :linux}, fn _ -> nil end)
      end
    end
  end
end
