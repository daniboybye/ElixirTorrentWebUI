defmodule ElixirTorrentWebUI.DataDir do
  @moduledoc false

  @app_support "ElixirTorrentWebUI"

  @spec root() :: Path.t()
  def root do
    cond do
      dir = Application.get_env(:elixir_torrent_web_ui, :data_dir) ->
        Path.expand(dir)

      dir = System.get_env("ELIXIR_TORRENT_DATA_DIR") ->
        Path.expand(dir)

      true ->
        default_root()
    end
  end

  @spec ensure!() :: :ok
  def ensure! do
    File.mkdir_p!(root())
    :ok
  end

  @spec use_cwd!() :: :ok
  def use_cwd! do
    File.cd!(root())
    :ok
  end

  @spec default_root() :: Path.t()
  defp default_root do
    case :os.type() do
      {:unix, :darwin} -> macos_application_support()
      {:unix, _} -> xdg_data_home()
      {:win32, _} -> windows_app_data()
    end
  end

  @spec macos_application_support() :: Path.t()
  defp macos_application_support do
    home =
      System.get_env("HOME") ||
        raise "HOME is not set; set ELIXIR_TORRENT_DATA_DIR to choose a data directory"

    Path.join([home, "Library", "Application Support", @app_support])
  end

  @spec xdg_data_home() :: Path.t()
  defp xdg_data_home do
    home = System.get_env("HOME") || File.cwd!()
    base = System.get_env("XDG_DATA_HOME") || Path.join(home, ".local/share")
    Path.join(base, @app_support)
  end

  @spec windows_app_data() :: Path.t()
  defp windows_app_data do
    base =
      System.get_env("LOCALAPPDATA") ||
        Path.join(System.get_env("USERPROFILE") || File.cwd!(), "AppData/Local")

    Path.join(base, @app_support)
  end
end
