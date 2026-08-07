defmodule ElixirTorrentWebUI.DefaultHandlerTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.DefaultHandler

  defp env_with_launcher(path),
    do: fn
      "ELIXIR_TORRENT_LAUNCHER" -> path
      _ -> nil
    end

  defp empty_env, do: fn _ -> nil end

  describe "status_command/2" do
    test "delegates to the launcher on macOS" do
      env =
        env_with_launcher("/Applications/ElixirTorrent Web.app/Contents/MacOS/ElixirTorrentWebUI")

      assert DefaultHandler.status_command({:unix, :darwin}, env) ==
               {:ok, "/Applications/ElixirTorrent Web.app/Contents/MacOS/ElixirTorrentWebUI",
                ["--check-defaults"]}
    end

    test "delegates to the launcher on Windows" do
      env = env_with_launcher("C:\\Apps\\ElixirTorrent\\Launcher.exe")

      assert DefaultHandler.status_command({:win32, :nt}, env) ==
               {:ok, "C:\\Apps\\ElixirTorrent\\Launcher.exe", ["--check-defaults"]}
    end

    test "returns launcher_unavailable when the launcher env is missing" do
      assert DefaultHandler.status_command({:unix, :darwin}, empty_env()) ==
               {:error, :launcher_unavailable}

      assert DefaultHandler.status_command({:win32, :nt}, empty_env()) ==
               {:error, :launcher_unavailable}
    end

    test "rejects unknown platforms" do
      assert DefaultHandler.status_command({:unix, :linux}, empty_env()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "register_command/2" do
    test "delegates to the launcher on macOS" do
      env =
        env_with_launcher("/Applications/ElixirTorrent Web.app/Contents/MacOS/ElixirTorrentWebUI")

      assert DefaultHandler.register_command({:unix, :darwin}, env) ==
               {:ok, "/Applications/ElixirTorrent Web.app/Contents/MacOS/ElixirTorrentWebUI",
                ["--register-defaults"]}
    end

    test "delegates to the launcher on Windows" do
      env = env_with_launcher("C:\\Apps\\ElixirTorrent\\Launcher.exe")

      assert DefaultHandler.register_command({:win32, :nt}, env) ==
               {:ok, "C:\\Apps\\ElixirTorrent\\Launcher.exe", ["--register-defaults"]}
    end

    test "returns launcher_unavailable when the launcher env is missing" do
      assert DefaultHandler.register_command({:unix, :darwin}, empty_env()) ==
               {:error, :launcher_unavailable}
    end

    test "rejects unknown platforms" do
      assert DefaultHandler.register_command({:unix, :linux}, empty_env()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "parse_status/1" do
    test "decodes a well-formed launcher payload" do
      assert DefaultHandler.parse_status(~s({"torrent":true,"magnet":false})) ==
               %{supported: true, torrent: true, magnet: false}
    end

    test "tolerates surrounding whitespace" do
      assert DefaultHandler.parse_status(~s(\n  {"torrent":true,"magnet":true}  \n)) ==
               %{supported: true, torrent: true, magnet: true}
    end

    test "treats missing keys as unsupported" do
      assert DefaultHandler.parse_status(~s({"torrent":true})) ==
               %{supported: false, torrent: nil, magnet: nil}
    end

    test "treats malformed JSON as unsupported" do
      assert DefaultHandler.parse_status("not json") ==
               %{supported: false, torrent: nil, magnet: nil}
    end
  end

  describe "both_default?/1 and needs_prompt?/1" do
    test "only true when supported and both defaults hold" do
      assert DefaultHandler.both_default?(%{supported: true, torrent: true, magnet: true})
      refute DefaultHandler.both_default?(%{supported: true, torrent: true, magnet: false})
      refute DefaultHandler.both_default?(%{supported: false, torrent: nil, magnet: nil})
    end

    test "prompt is needed only when supported and either default is missing" do
      assert DefaultHandler.needs_prompt?(%{supported: true, torrent: false, magnet: false})
      assert DefaultHandler.needs_prompt?(%{supported: true, torrent: true, magnet: false})
      refute DefaultHandler.needs_prompt?(%{supported: true, torrent: true, magnet: true})
      refute DefaultHandler.needs_prompt?(%{supported: false, torrent: nil, magnet: nil})
    end
  end
end
