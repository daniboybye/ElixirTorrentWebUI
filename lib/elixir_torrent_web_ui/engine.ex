defmodule ElixirTorrentWebUI.Engine do
  @moduledoc """
  Thin adapter around the `:elixir_torrent` engine.

  UI code should depend on this module (not on engine internals).
  """

  defmodule FileRow do
    @enforce_keys [:index, :path, :name, :length, :downloaded, :progress, :complete?]
    defstruct [:index, :path, :name, :length, :downloaded, :progress, :complete?]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            path: String.t(),
            name: String.t(),
            length: non_neg_integer(),
            downloaded: non_neg_integer(),
            progress: float(),
            complete?: boolean()
          }
  end

  defmodule TorrentRow do
    @enforce_keys [
      :id,
      :hash,
      :name,
      :progress,
      :bytes_downloaded,
      :bytes_size,
      :down_kbps,
      :up_kbps,
      :peers,
      :status,
      :eta_seconds,
      :file_count,
      :added_at,
      :files
    ]
    defstruct [
      :id,
      :hash,
      :name,
      :progress,
      :bytes_downloaded,
      :bytes_size,
      :down_kbps,
      :up_kbps,
      :peers,
      :status,
      :eta_seconds,
      :file_count,
      :added_at,
      :files
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            hash: Torrent.hash(),
            name: String.t(),
            progress: float(),
            bytes_downloaded: non_neg_integer(),
            bytes_size: non_neg_integer(),
            down_kbps: number(),
            up_kbps: number(),
            peers: non_neg_integer(),
            status: String.t(),
            eta_seconds: nil | :infinity | float(),
            file_count: non_neg_integer(),
            added_at: DateTime.t() | nil,
            files: [FileRow.t()]
          }
  end

  @spec list_torrents(MapSet.t()) :: list(TorrentRow.t())
  def list_torrents(expanded \\ MapSet.new()) do
    Torrents
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case Torrent.get_hash(pid) do
          nil -> []
          hash -> [row_for(hash, expanded)]
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

  @spec row_for(Torrent.hash(), MapSet.t()) :: TorrentRow.t()
  defp row_for(hash, expanded) do
    id = Torrent.hex_encoded_hash(hash)

    [name, speed, downloaded, size, peer_status, added_at] =
      Torrent.get(hash, [:name, :speed, :downloaded, :bytes_size, :peer_status, :added_at])

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

    status = status_string(peer_status)

    files =
      if MapSet.member?(expanded, id) do
        list_files(hash)
      else
        []
      end

    %TorrentRow{
      id: id,
      hash: hash,
      name: name,
      progress: progress,
      bytes_downloaded: downloaded,
      bytes_size: size,
      down_kbps: speed.download,
      up_kbps: speed.upload,
      peers: peers,
      status: status,
      eta_seconds: compute_eta(status, size - downloaded, speed.download, peers),
      file_count: Torrent.file_count(hash),
      added_at: added_at,
      files: files
    }
  end

  @spec list_files(Torrent.hash()) :: [FileRow.t()]
  defp list_files(hash) do
    hash
    |> Torrent.list_files()
    |> Enum.map(fn entry ->
      %FileRow{
        index: entry.index,
        path: entry.path,
        name: entry.name,
        length: entry.length,
        downloaded: entry.downloaded,
        progress: entry.progress,
        complete?: entry.complete?
      }
    end)
  end

  @spec compute_eta(String.t(), non_neg_integer(), number(), non_neg_integer()) ::
          nil | :infinity | float()
  defp compute_eta("Seeding", _left, _kbps, _peers), do: nil
  defp compute_eta(_status, 0, _kbps, _peers), do: nil
  defp compute_eta(_status, _left, _kbps, 0), do: :infinity
  defp compute_eta(_status, _left, kbps, _peers) when kbps <= 0, do: :infinity

  defp compute_eta(_status, left, kbps, _peers) do
    left / (kbps * 1024)
  end

  @spec status_string(Peer.status()) :: String.t()
  defp status_string(:seed), do: "Seeding"
  defp status_string(:connecting_to_peers), do: "Connecting"
  defp status_string(nil), do: "Idle"
  defp status_string(index) when is_integer(index), do: "Downloading"
end
