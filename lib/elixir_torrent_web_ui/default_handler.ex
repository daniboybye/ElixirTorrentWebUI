defmodule ElixirTorrentWebUI.DefaultHandler do
  @moduledoc false

  alias ElixirTorrentWebUI.CommandEnvironment

  # Coordinates the "am I the default program for .torrent files and magnet:
  # links" question across macOS and Windows. Actual OS work happens inside the
  # native launcher — this module only shells out to it via
  # ELIXIR_TORRENT_LAUNCHER and interprets its stdout.

  @type os_type :: {:unix, atom()} | {:win32, atom()}
  @type env_fun :: (String.t() -> String.t() | nil)
  @type command :: {:ok, String.t(), [String.t()]} | {:error, atom()}

  @type status :: %{
          required(:supported) => boolean(),
          required(:torrent) => boolean() | nil,
          required(:magnet) => boolean() | nil
        }

  @launcher_env "ELIXIR_TORRENT_LAUNCHER"
  @unsupported %{supported: false, torrent: nil, magnet: nil}

  @spec status() :: status()
  def status, do: status(:os.type(), &System.get_env/1)

  @doc false
  @spec status(os_type(), env_fun()) :: status()
  def status(os_type, env) do
    case status_command(os_type, env) do
      {:ok, cmd, args} ->
        case System.cmd(cmd, args,
               env: CommandEnvironment.scrubbed(),
               stderr_to_stdout: false
             ) do
          {output, 0} -> parse_status(output)
          _ -> @unsupported
        end

      {:error, _} ->
        @unsupported
    end
  rescue
    ErlangError -> @unsupported
  end

  @spec request_default() :: :ok | {:error, atom()}
  def request_default, do: request_default(:os.type(), &System.get_env/1)

  @doc false
  @spec request_default(os_type(), env_fun()) :: :ok | {:error, atom()}
  def request_default(os_type, env) do
    case register_command(os_type, env) do
      {:ok, cmd, args} ->
        case System.cmd(cmd, args,
               env: CommandEnvironment.scrubbed(),
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          _ -> {:error, :register_failed}
        end

      {:error, _} = err ->
        err
    end
  rescue
    ErlangError -> {:error, :register_failed}
  end

  # Blocks the calling process, so callers must run this off the LiveView
  # process (e.g. inside `start_async/3`) rather than in a request handler.
  # The launcher does its own polling internally and only returns once the
  # OS actually reflects the change (or a generous timeout elapses) — a real
  # notification from the platform layer instead of Elixir re-asking
  # `status/0` on a fixed timer.
  @spec await_default() :: status()
  def await_default, do: await_default(:os.type(), &System.get_env/1)

  @doc false
  @spec await_default(os_type(), env_fun()) :: status()
  def await_default(os_type, env) do
    case await_command(os_type, env) do
      {:ok, cmd, args} ->
        case System.cmd(cmd, args,
               env: CommandEnvironment.scrubbed(),
               stderr_to_stdout: false
             ) do
          {output, 0} -> parse_status(output)
          _ -> @unsupported
        end

      {:error, _} ->
        @unsupported
    end
  rescue
    ErlangError -> @unsupported
  end

  @spec both_default?(status()) :: boolean()
  def both_default?(%{supported: true, torrent: true, magnet: true}), do: true
  def both_default?(_), do: false

  @spec needs_prompt?(status()) :: boolean()
  def needs_prompt?(%{supported: true} = status), do: not both_default?(status)
  def needs_prompt?(_), do: false

  @doc false
  @spec status_command(os_type(), env_fun()) :: command()
  def status_command({:unix, :darwin}, env), do: launcher_command(env, "--check-defaults")
  def status_command({:win32, _}, env), do: launcher_command(env, "--check-defaults")
  def status_command(_os_type, _env), do: {:error, :unsupported_platform}

  @doc false
  @spec register_command(os_type(), env_fun()) :: command()
  def register_command({:unix, :darwin}, env), do: launcher_command(env, "--register-defaults")
  def register_command({:win32, _}, env), do: launcher_command(env, "--register-defaults")
  def register_command(_os_type, _env), do: {:error, :unsupported_platform}

  @doc false
  @spec await_command(os_type(), env_fun()) :: command()
  def await_command({:unix, :darwin}, env), do: launcher_command(env, "--await-default-status")
  def await_command({:win32, _}, env), do: launcher_command(env, "--await-default-status")
  def await_command(_os_type, _env), do: {:error, :unsupported_platform}

  @doc false
  @spec parse_status(String.t()) :: status()
  def parse_status(output) when is_binary(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"torrent" => t, "magnet" => m}} when is_boolean(t) and is_boolean(m) ->
        %{supported: true, torrent: t, magnet: m}

      _ ->
        @unsupported
    end
  end

  defp launcher_command(env, arg) do
    case env.(@launcher_env) do
      launcher when is_binary(launcher) and launcher != "" ->
        {:ok, launcher, [arg]}

      _ ->
        {:error, :launcher_unavailable}
    end
  end
end
