defmodule ElixirTorrentWebUI.OsIntegration do
  @moduledoc false

  @sensitive_env_vars ["SECRET_KEY_BASE"]

  @spec open_file(Path.t()) :: :ok | {:error, term()}
  def open_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, command, args} <- open_file_command(:os.type(), path) do
      case system_cmd(command, args, stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ -> {:error, :open_failed}
      end
    else
      false -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec open_file_command({:unix | :win32, atom()}, Path.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, :unsupported_platform}
  def open_file_command({:unix, :darwin}, path), do: {:ok, "open", [path]}
  def open_file_command(_os_type, _path), do: {:error, :unsupported_platform}

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
end
