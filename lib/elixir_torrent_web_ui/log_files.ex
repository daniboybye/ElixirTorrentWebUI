defmodule ElixirTorrentWebUI.LogFiles do
  @moduledoc false

  # Logs written while ElixirTorrent runs live directly in the data directory:
  # `server.log` (release stdout/stderr, including Engine output), `debug.log`
  # and the rotated `*.log.N` siblings.
  #
  # The desktop launcher keeps `server.log` open for the life of the server, so
  # deleting it would leave the release writing into an unlinked file. Active
  # logs are therefore truncated in place and only rotated copies are removed.

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:elixir_torrent_web_ui, :debug_tools, false)

  @spec delete_all(Path.t()) :: {:ok, non_neg_integer()} | {:error, [{Path.t(), term()}]}
  def delete_all(root \\ ElixirTorrentWebUI.DataDir.root()) do
    results =
      Enum.map(active_logs(root), &truncate/1) ++ Enum.map(rotated_logs(root), &remove/1)

    case for({:error, _} = error <- results, do: error) do
      [] -> {:ok, Enum.count(results, &(&1 == :ok))}
      errors -> {:error, Enum.map(errors, fn {:error, failure} -> failure end)}
    end
  end

  @spec active_logs(Path.t()) :: [Path.t()]
  defp active_logs(root), do: wildcard_files(Path.join(root, "*.log"))

  @spec rotated_logs(Path.t()) :: [Path.t()]
  defp rotated_logs(root), do: wildcard_files(Path.join(root, "*.log.[0-9]*"))

  @spec wildcard_files(Path.t()) :: [Path.t()]
  defp wildcard_files(pattern), do: Enum.filter(Path.wildcard(pattern), &regular?/1)

  @spec regular?(Path.t()) :: boolean()
  defp regular?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.stat(path))

  @spec truncate(Path.t()) :: :ok | {:error, {Path.t(), term()}}
  defp truncate(path) do
    case File.write(path, "") do
      :ok -> :ok
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  @spec remove(Path.t()) :: :ok | {:error, {Path.t(), term()}}
  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {path, reason}}
    end
  end
end
