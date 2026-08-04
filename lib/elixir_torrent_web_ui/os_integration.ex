defmodule ElixirTorrentWebUI.OsIntegration do
  @moduledoc false

  @spec open_file(Path.t()) :: :ok | {:error, term()}
  def open_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, command, args} <- open_file_command(:os.type(), path) do
      case System.cmd(command, args, stderr_to_stdout: true) do
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
end
