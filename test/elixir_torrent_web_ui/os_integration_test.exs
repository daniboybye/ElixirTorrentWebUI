defmodule ElixirTorrentWebUI.OsIntegrationTest do
  # Mutates the OS process environment via System.put_env/2, so this suite
  # cannot run concurrently with other tests that read the same env vars.
  use ExUnit.Case, async: false

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
