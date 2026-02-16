defmodule ElixirTorrentWebUI.Engine do
  @moduledoc """
  Thin adapter around the `:elixir_torrent` engine.

  UI code should depend on this module (not on engine internals).
  """

  defmodule TorrentRow do
    @enforce_keys [:hash, :name, :progress, :down_kbps, :up_kbps, :peers, :status]
    defstruct [:hash, :name, :progress, :down_kbps, :up_kbps, :peers, :status]

    @type t :: %__MODULE__{
            hash: Torrent.hash(),
            name: String.t(),
            progress: float(),
            down_kbps: number(),
            up_kbps: number(),
            peers: non_neg_integer(),
            status: String.t()
          }
  end

  @spec list_torrents() :: list(TorrentRow.t())
  def list_torrents do
    Torrents
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case Torrent.get_hash(pid) do
          nil ->
            []

          hash ->
            [row_for(hash)]
        end

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.name)
  end

  @spec add_torrent(Path.t()) :: DynamicSupervisor.on_start_child()
  def add_torrent(path) do
    ElixirTorrent.download(path)
  end

  @spec row_for(Torrent.hash()) :: TorrentRow.t()
  defp row_for(hash) do
    [name, speed, downloaded, size, peer_status] =
      Torrent.get(hash, [:name, :speed, :downloaded, :bytes_size, :peer_status])

    progress =
      if size > 0 do
        downloaded * 100.0 / size
      else
        0.0
      end

    peers =
      try do
        Torrent.Swarm.count(hash)
      rescue
        _ -> 0
      end

    %TorrentRow{
      hash: hash,
      name: name,
      progress: progress,
      down_kbps: speed.download,
      up_kbps: speed.upload,
      peers: peers,
      status: status_string(peer_status)
    }
  end

  @spec status_string(Peer.status()) :: String.t()
  defp status_string(:seed), do: "Seeding"
  defp status_string(:connecting_to_peers), do: "Connecting"
  defp status_string(nil), do: "Idle"
  defp status_string(index) when is_integer(index), do: "Downloading (piece #{index})"
end
