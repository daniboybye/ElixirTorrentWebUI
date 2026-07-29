defmodule ElixirTorrentWebUI.MagnetIngest do
  @moduledoc false

  require Logger

  @pubsub ElixirTorrentWebUI.PubSub
  @topic "torrents:magnet"
  @table __MODULE__
  @result_key :last_result
  @result_ttl_sec 300

  @spec ensure_table!() :: :ok
  def ensure_table! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @spec take_last_result() :: {String.t(), {:ok, pid() | :fetching} | {:error, term()}} | nil
  def take_last_result do
    ensure_table!()

    case :ets.lookup(@table, @result_key) do
      [{@result_key, uri, result, at}] ->
        :ets.delete(@table, @result_key)

        if System.monotonic_time(:second) - at <= @result_ttl_sec do
          {uri, result}
        else
          nil
        end

      _ ->
        nil
    end
  end

  @spec submit(String.t()) :: :ok
  def submit(magnet_uri) when is_binary(magnet_uri) do
    uri = String.trim(magnet_uri)
    Logger.debug("MagnetIngest: queued magnet")
    :ok = ElixirTorrentWebUI.PendingMagnets.register(uri)

    Task.start(fn ->
      result =
        try do
          ElixirTorrentWebUI.Engine.add_magnet(uri)
        rescue
          exception ->
            Logger.error(
              "MagnetIngest: add_magnet crashed exception=#{Exception.format(:error, exception, __STACKTRACE__)}"
            )

            {:error, exception}
        end

      normalized = normalize_result(result)
      Logger.debug("MagnetIngest: finished result=#{inspect(normalized)}")
      remember_result(uri, normalized)
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:magnet_ingest, uri, normalized})
    end)

    :ok
  end

  @spec remember_result(String.t(), {:ok, pid() | :fetching} | {:error, term()}) :: :ok
  defp remember_result(uri, result) do
    ensure_table!()
    :ets.insert(@table, {@result_key, uri, result, System.monotonic_time(:second)})
    :ok
  end

  @spec normalize_result({:ok, pid() | :fetching} | {:error, term()}) ::
          {:ok, pid() | :fetching} | {:error, term()}
  defp normalize_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp normalize_result({:ok, :fetching}), do: {:ok, :fetching}
  defp normalize_result({:error, reason}), do: {:error, reason}

  @spec topic() :: String.t()
  def topic, do: @topic
end
