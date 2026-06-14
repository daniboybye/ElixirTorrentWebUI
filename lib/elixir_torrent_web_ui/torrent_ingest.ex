defmodule ElixirTorrentWebUI.TorrentIngest do
  @moduledoc false

  @pubsub ElixirTorrentWebUI.PubSub
  @topic "torrents:file"

  @spec submit(Path.t()) :: :ok
  def submit(path) when is_binary(path) do
    Task.start(fn ->
      result = ElixirTorrentWebUI.Engine.add_torrent(path)
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:torrent_ingest, path, result})
    end)

    :ok
  end

  @spec topic() :: String.t()
  def topic, do: @topic
end
