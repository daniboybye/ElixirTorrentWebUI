defmodule ElixirTorrentWebUI.LogFilesTest do
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.LogFiles

  @moduletag :tmp_dir

  test "truncates active logs and removes rotated copies", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "server.log"), "server")
    File.write!(Path.join(dir, "debug.log"), "debug")
    File.write!(Path.join(dir, "server.log.1"), "rotated")
    File.write!(Path.join(dir, "stats.json"), "{}")

    assert {:ok, 3} = LogFiles.delete_all(dir)

    assert File.read!(Path.join(dir, "server.log")) == ""
    assert File.read!(Path.join(dir, "debug.log")) == ""
    refute File.exists?(Path.join(dir, "server.log.1"))
    assert File.read!(Path.join(dir, "stats.json")) == "{}"
  end

  test "does nothing when there are no logs", %{tmp_dir: dir} do
    assert {:ok, 0} = LogFiles.delete_all(dir)
  end

  test "ignores directories named like logs", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "weird.log"))

    assert {:ok, 0} = LogFiles.delete_all(dir)
    assert File.dir?(Path.join(dir, "weird.log"))
  end

  test "reports files that cannot be modified", %{tmp_dir: dir} do
    log = Path.join(dir, "server.log")
    File.write!(log, "server")
    File.chmod!(log, 0o444)
    on_exit(fn -> File.chmod(log, 0o644) end)

    if File.stat!(log).access == :read and System.get_env("USER") != "root" do
      assert {:error, [{^log, :eacces}]} = LogFiles.delete_all(dir)
    end
  end

  test "is enabled only through the :debug_tools flag" do
    previous = Application.get_env(:elixir_torrent_web_ui, :debug_tools)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:elixir_torrent_web_ui, :debug_tools),
        else: Application.put_env(:elixir_torrent_web_ui, :debug_tools, previous)
    end)

    Application.delete_env(:elixir_torrent_web_ui, :debug_tools)
    refute LogFiles.enabled?()

    Application.put_env(:elixir_torrent_web_ui, :debug_tools, true)
    assert LogFiles.enabled?()
  end
end
