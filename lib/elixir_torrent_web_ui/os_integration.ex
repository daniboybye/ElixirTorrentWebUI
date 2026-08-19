defmodule ElixirTorrentWebUI.OsIntegration do
  @moduledoc false

  alias ElixirTorrentWebUI.CommandEnvironment

  @type os_type :: {:unix, atom()} | {:win32, atom()}
  @type env_fun :: (String.t() -> String.t() | nil)
  @type command :: {:ok, String.t(), [String.t()]} | {:error, atom()}

  @launcher_env "ELIXIR_TORRENT_LAUNCHER"
  @sensitive_env_vars ["SECRET_KEY_BASE"]

  # -- open_file --------------------------------------------------------------

  @spec open_file(Path.t()) :: :ok | {:error, term()}
  def open_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, command, args} <- open_file_command(:os.type(), path, &System.get_env/1) do
      case System.cmd(command, args,
             env: CommandEnvironment.scrubbed(),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        _ -> {:error, :open_failed}
      end
    else
      false -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec open_file_command(os_type(), Path.t(), env_fun()) :: command()
  def open_file_command({:unix, :darwin}, path, _env), do: {:ok, "open", [path]}

  def open_file_command({:win32, _}, path, env) do
    case env.(@launcher_env) do
      launcher when is_binary(launcher) and launcher != "" ->
        {:ok, launcher, ["--open-file", path]}

      _ ->
        {:ok, "explorer.exe", [path]}
    end
  end

  def open_file_command(_os_type, _path, _env), do: {:error, :unsupported_platform}

  @doc """
  Runs `System.cmd/3`, stripping known sensitive env vars (e.g.
  `SECRET_KEY_BASE`) from the spawned process's inherited environment.
  """
  @spec system_cmd(String.t(), [String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  def system_cmd(command, args, opts \\ []) do
    System.cmd(command, args, Keyword.update(opts, :env, redacted_env(), &(&1 ++ redacted_env())))
  end

  @doc false
  @spec redacted_env() :: [{String.t(), nil}]
  def redacted_env do
    Enum.map(@sensitive_env_vars, &{&1, nil})
  end

  # -- reveal (single file or directory) --------------------------------------

  # Judged by the command, not by the platform. explorer.exe exits 1 even when it
  # opened the window, so its status carries no information — but the launcher
  # returns meaningful codes (1 missing target, 2 failed), and folding those into
  # :ok reported success for reveals that did nothing at all.
  @doc false
  @spec reveal_result(String.t(), non_neg_integer()) :: :ok | {:error, :open_failed}
  def reveal_result("explorer.exe", _status), do: :ok
  def reveal_result(_command, 0), do: :ok
  def reveal_result(_command, _status), do: {:error, :open_failed}

  @doc false
  @spec reveal_command(os_type(), Path.t(), :file | :dir, env_fun()) :: command()
  def reveal_command({:unix, :darwin}, path, :file, _env), do: {:ok, "open", ["-R", path]}
  def reveal_command({:unix, :darwin}, path, :dir, _env), do: {:ok, "open", [path]}

  # Prefer the launcher, exactly as open_file/1 does. explorer.exe needs the
  # literal command line /select,"C:\dir\file", and System.cmd/3 cannot produce
  # it: ["/select,", path] reaches explorer as two separate operands, while
  # ["/select," <> path] is one token that Erlang wraps in quotes as soon as the
  # path contains a space. Neither is the required form; only a raw command line
  # is, which the launcher builds. explorer.exe stays as the fallback for a
  # directory, where there is no switch and argv is fine.
  def reveal_command({:win32, _}, path, kind, env) do
    case env.(@launcher_env) do
      launcher when is_binary(launcher) and launcher != "" ->
        {:ok, launcher, ["--reveal", path]}

      _ when kind == :dir ->
        {:ok, "explorer.exe", [path]}

      _ ->
        {:ok, "explorer.exe", ["/select," <> path]}
    end
  end

  def reveal_command(_os_type, _path, _kind, _env), do: {:error, :unsupported_platform}

  # -- show_folder (list of paths belonging to a torrent) ---------------------

  @spec show_folder([Path.t()]) :: :ok | {:error, term()}
  def show_folder(paths) when is_list(paths) do
    with {:ok, target, kind} <- pick_reveal_target(paths) do
      reveal_from_target(target, kind)
    end
  end

  defp pick_reveal_target([single]) when is_binary(single) do
    cond do
      File.regular?(single) -> {:ok, single, :file}
      File.dir?(single) -> {:ok, single, :dir}
      File.dir?(Path.dirname(single)) -> {:ok, Path.dirname(single), :dir}
      true -> {:error, :missing}
    end
  end

  defp pick_reveal_target(paths) when is_list(paths) and paths != [] do
    dir = common_ancestor(paths)

    if File.dir?(dir) do
      {:ok, dir, :dir}
    else
      {:error, :missing}
    end
  end

  defp pick_reveal_target(_), do: {:error, :missing}

  defp reveal_from_target(target, kind) do
    case reveal_command(:os.type(), target, kind, &System.get_env/1) do
      {:ok, cmd, args} ->
        {_, status} =
          System.cmd(cmd, args,
            env: CommandEnvironment.scrubbed(),
            stderr_to_stdout: true
          )

        reveal_result(cmd, status)

      {:error, _} = err ->
        err
    end
  end

  # -- pick_download_folder ---------------------------------------------------

  @spec pick_download_folder() :: {:ok, Path.t()} | {:error, term()}
  def pick_download_folder do
    with {:ok, cmd, args} <- pick_folder_command(:os.type(), &System.get_env/1),
         {output, 0} <-
           System.cmd(cmd, args,
             env: CommandEnvironment.scrubbed(),
             stderr_to_stdout: true
           ) do
      case String.trim(output) do
        "" -> {:error, :cancelled}
        path -> {:ok, path}
      end
    else
      {:error, _} = err -> err
      _ -> {:error, :cancelled}
    end
  end

  @doc false
  @spec pick_folder_command(os_type(), env_fun()) :: command()
  def pick_folder_command({:unix, :darwin}, _env) do
    script = ~s'POSIX path of (choose folder with prompt "Choose download folder")'
    {:ok, "osascript", ["-e", script]}
  end

  def pick_folder_command({:win32, _}, env) do
    case env.(@launcher_env) do
      launcher when is_binary(launcher) and launcher != "" ->
        {:ok, launcher, ["--pick-folder"]}

      _ ->
        {:error, :launcher_unavailable}
    end
  end

  def pick_folder_command(_os_type, _env), do: {:error, :unsupported_platform}

  # -- helpers ----------------------------------------------------------------

  @spec common_ancestor([Path.t()]) :: Path.t()
  defp common_ancestor([first | rest]) do
    rest
    |> Enum.reduce(Path.split(first), &common_path_parts/2)
    |> Path.join()
  end

  defp common_path_parts(path, acc) do
    acc
    |> Enum.zip(Path.split(path))
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map(fn {part, _} -> part end)
  end
end
