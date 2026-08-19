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

    test "delegates a file reveal to the launcher on Windows" do
      # The launcher builds explorer's raw /select,"path" command line, which
      # System.cmd/3 cannot express.
      env = %{"ELIXIR_TORRENT_LAUNCHER" => "C:\\Apps\\Launcher.exe"}

      assert OsIntegration.reveal_command(
               {:win32, :nt},
               "D:\\x\\photo.jpg",
               :file,
               &Map.get(env, &1)
             ) ==
               {:ok, "C:\\Apps\\Launcher.exe", ["--reveal", "D:\\x\\photo.jpg"]}
    end

    test "delegates a directory reveal to the launcher on Windows" do
      env = %{"ELIXIR_TORRENT_LAUNCHER" => "C:\\Apps\\Launcher.exe"}

      assert OsIntegration.reveal_command({:win32, :nt}, "D:\\x", :dir, &Map.get(env, &1)) ==
               {:ok, "C:\\Apps\\Launcher.exe", ["--reveal", "D:\\x"]}
    end

    test "falls back to explorer.exe when the launcher is not registered" do
      assert OsIntegration.reveal_command({:win32, :nt}, "D:\\x", :dir, empty_env()) ==
               {:ok, "explorer.exe", ["D:\\x"]}

      assert OsIntegration.reveal_command({:win32, :nt}, "D:\\x\\photo.jpg", :file, empty_env()) ==
               {:ok, "explorer.exe", ["/select,D:\\x\\photo.jpg"]}
    end

    test "rejects unknown platforms" do
      assert OsIntegration.reveal_command({:unix, :linux}, "/x", :dir, empty_env()) ==
               {:error, :unsupported_platform}
    end
  end

  describe "reveal_result/2" do
    test "ignores explorer.exe's exit status, which is 1 even on success" do
      assert OsIntegration.reveal_result("explorer.exe", 1) == :ok
      assert OsIntegration.reveal_result("explorer.exe", 0) == :ok
    end

    test "honours the launcher's exit status, which is meaningful" do
      # 1 = target missing, 2 = the call failed. Folding these into :ok told the
      # UI a reveal had worked when nothing opened.
      launcher = "C:\\Apps\\Launcher.exe"

      assert OsIntegration.reveal_result(launcher, 0) == :ok
      assert OsIntegration.reveal_result(launcher, 1) == {:error, :open_failed}
      assert OsIntegration.reveal_result(launcher, 2) == {:error, :open_failed}
    end

    test "honours the exit status on other platforms" do
      assert OsIntegration.reveal_result("open", 0) == :ok
      assert OsIntegration.reveal_result("open", 1) == {:error, :open_failed}
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
      System.put_env("OS_INTEGRATION_SENTINEL", "present")

      on_exit(fn ->
        System.delete_env("SECRET_KEY_BASE")
        System.delete_env("OS_INTEGRATION_SENTINEL")
      end)

      {command, args} = env_dump_command()
      {output, 0} = OsIntegration.system_cmd(command, args, [])

      refute output =~ "SECRET_KEY_BASE"
      # Proves the dump actually ran, without depending on `PATH` casing —
      # Windows spells it `Path`.
      assert output =~ "OS_INTEGRATION_SENTINEL=present"
    end

    test "still merges in env vars the caller explicitly passes" do
      {command, args} = env_dump_command()

      {output, 0} =
        OsIntegration.system_cmd(command, args, env: [{"OS_INTEGRATION_TEST_VAR", "hi"}])

      assert output =~ "OS_INTEGRATION_TEST_VAR=hi"
    end

    # `env` does not exist on Windows; `cmd /c set` is the equivalent dump and
    # emits the same NAME=value lines these assertions match on.
    defp env_dump_command do
      case :os.type() do
        {:win32, _} -> {"cmd", ["/c", "set"]}
        _ -> {"env", []}
      end
    end
  end
end
