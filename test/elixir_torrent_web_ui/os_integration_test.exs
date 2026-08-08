defmodule ElixirTorrentWebUI.OsIntegrationTest do
  # Mutates the OS process environment via System.put_env/2, so this suite
  # cannot run concurrently with other tests that read the same env vars.
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.OsIntegration

  defp empty_env, do: fn _ -> nil end

  describe "open_file_command/3" do
    test "uses the macOS default application without invoking a shell" do
      path = "/tmp/photo with spaces.jpg"

      assert OsIntegration.open_file_command({:unix, :darwin}, path, empty_env()) ==
               {:ok, "open", [path]}
    end

    test "prefers the launcher binary on Windows when ELIXIR_TORRENT_LAUNCHER is set" do
      env = %{"ELIXIR_TORRENT_LAUNCHER" => "C:\\Program Files\\ElixirTorrent\\Launcher.exe"}
      path = "D:\\Photos\\image.jpg"

      assert OsIntegration.open_file_command({:win32, :nt}, path, &Map.get(env, &1)) ==
               {:ok, "C:\\Program Files\\ElixirTorrent\\Launcher.exe", ["--open-file", path]}
    end

    test "falls back to explorer.exe on Windows when the launcher is not registered" do
      path = "D:\\Photos\\image.jpg"

      assert OsIntegration.open_file_command({:win32, :nt}, path, empty_env()) ==
               {:ok, "explorer.exe", [path]}
    end

    test "rejects unknown platforms" do
      assert OsIntegration.open_file_command({:unix, :linux}, "/tmp/x.jpg", empty_env()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "reveal_command/4" do
    test "opens Finder around the file on macOS" do
      assert OsIntegration.reveal_command({:unix, :darwin}, "/x/photo.jpg", :file, empty_env()) ==
               {:ok, "open", ["-R", "/x/photo.jpg"]}
    end

    test "opens Finder on a directory on macOS" do
      assert OsIntegration.reveal_command({:unix, :darwin}, "/x", :dir, empty_env()) ==
               {:ok, "open", ["/x"]}
    end

    test "selects the file inside Explorer on Windows" do
      assert OsIntegration.reveal_command({:win32, :nt}, "D:\\x\\photo.jpg", :file, empty_env()) ==
               {:ok, "explorer.exe", ["/select,", "D:\\x\\photo.jpg"]}
    end

    test "opens the directory in Explorer on Windows" do
      assert OsIntegration.reveal_command({:win32, :nt}, "D:\\x", :dir, empty_env()) ==
               {:ok, "explorer.exe", ["D:\\x"]}
    end

    test "rejects unknown platforms" do
      assert OsIntegration.reveal_command({:unix, :linux}, "/x", :dir, empty_env()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "pick_folder_command/2" do
    test "uses osascript on macOS" do
      assert {:ok, "osascript", ["-e", script]} =
               OsIntegration.pick_folder_command({:unix, :darwin}, empty_env())

      assert script =~ "choose folder"
    end

    test "delegates to the launcher on Windows" do
      env = %{"ELIXIR_TORRENT_LAUNCHER" => "C:\\Apps\\Launcher.exe"}

      assert OsIntegration.pick_folder_command({:win32, :nt}, &Map.get(env, &1)) ==
               {:ok, "C:\\Apps\\Launcher.exe", ["--pick-folder"]}
    end

    test "returns launcher_unavailable when the Windows launcher path is missing" do
      assert OsIntegration.pick_folder_command({:win32, :nt}, empty_env()) ==
               {:error, :launcher_unavailable}
    end

    test "rejects unknown platforms" do
      assert OsIntegration.pick_folder_command({:unix, :linux}, empty_env()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "redacted_env/0" do
    test "lists the sensitive env vars to unset" do
      assert OsIntegration.redacted_env() == [{"SECRET_KEY_BASE", nil}]
    end
  end

  describe "system_cmd/3" do
    test "strips sensitive env vars from the spawned process's environment" do
      System.put_env("SECRET_KEY_BASE", "super-secret-value")
      on_exit(fn -> System.delete_env("SECRET_KEY_BASE") end)

      {output, 0} = OsIntegration.system_cmd("env", [], [])

      refute output =~ "SECRET_KEY_BASE"
      assert output =~ "PATH="
    end

    test "still merges in env vars the caller explicitly passes" do
      {output, 0} = OsIntegration.system_cmd("env", [], env: [{"OS_INTEGRATION_TEST_VAR", "hi"}])

      assert output =~ "OS_INTEGRATION_TEST_VAR=hi"
    end
  end
end
