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

      # Suffix, not equality: the implementation normalizes through
      # `Path.expand/1`, which is host-dependent — on a Windows host it prefixes
      # the current drive, yielding "c:/Users/daniel/Downloads". Asserting the
      # suffix keeps this case meaningful on every host instead of only where
      # the os_type argument happens to match the machine running the suite.
      assert UiState.default_download_folder({:unix, :darwin}, &Map.get(env, &1))
             |> String.ends_with?("/Users/daniel/Downloads")
    end

    test "raises on Unix hosts when HOME is not set" do
      assert_raise RuntimeError, ~r/HOME is not set/, fn ->
        UiState.default_download_folder({:unix, :linux}, fn _ -> nil end)
      end
    end
  end
end
