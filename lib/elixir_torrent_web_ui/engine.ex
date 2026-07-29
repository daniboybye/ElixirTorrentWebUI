defmodule ElixirTorrentWebUI.Engine do
  @moduledoc """
  Thin adapter around the `:elixir_torrent` engine.

  UI code should depend on this module (not on engine internals).
  """

  alias ElixirTorrentWebUI.{Media, TorrentCatalog, UiState}

  @min_play_progress_percent 1.0

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
    catalog =
      TorrentCatalog.entries()
      |> Map.new(&{&1.id, &1})

    order =
      TorrentCatalog.ordered_ids()
      |> Enum.with_index()
      |> Map.new()

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
    |> Enum.map(&merge_catalog(&1, catalog))
    |> Enum.sort_by(&Map.get(order, &1.id, 999_999))
  end

  @spec add_torrent(Path.t()) :: DynamicSupervisor.on_start_child()
  def add_torrent(path) do
    download_dir = UiState.get().download_folder

    with {:ok, pid} <- ElixirTorrent.download(path, download_dir: download_dir),
         hash when is_binary(hash) <- Torrent.get_hash(pid),
         [name] <- Torrent.get(hash, [:name]) do
      id = Torrent.hex_encoded_hash(hash)
      dest = TorrentCatalog.durable_torrent_path(id)

      File.mkdir_p!(TorrentCatalog.torrents_dir())
      File.cp!(path, dest)
      :ok = TorrentCatalog.register(hash, dest, name, download_dir)

      {:ok, pid}
    end
  end

  @spec remove_torrent(Torrent.hash(), keyword()) :: :ok | {:error, term()}
  def remove_torrent(hash, opts \\ []) do
    id = Torrent.hex_encoded_hash(hash)

    with :ok <- ElixirTorrent.remove(hash, opts) do
      TorrentCatalog.remove(id)
    end
  end

  @spec merge_catalog(TorrentRow.t(), map()) :: TorrentRow.t()
  defp merge_catalog(row, catalog) do
    case Map.get(catalog, row.id) do
      %{name: name, added_at: added_at} -> %{row | name: name, added_at: added_at}
      _ -> row
    end
  end

  @spec playable_file?(FileRow.t()) :: boolean()
  def playable_file?(%FileRow{progress: progress, name: name, path: path}) do
    progress >= @min_play_progress_percent and (Media.video?(name) or Media.video?(path))
  end

  @spec resolve_video(String.t(), non_neg_integer()) ::
          {:ok, %{name: String.t(), path: Path.t(), content_type: String.t()}}
          | {:error, term()}
  def resolve_video(torrent_id, file_index) do
    with {:ok, hash} <- hash_from_hex_id(torrent_id),
         {:ok, file} <- find_file(hash, file_index),
         :ok <- validate_playable(file),
         {:ok, path} <- safe_disk_path(file.path, torrent_id),
         :ok <- ensure_readable(path),
         {:ok, content_type} <- Media.content_type(file.name) do
      {:ok, %{name: file.name, path: path, content_type: content_type}}
    end
  end

  @spec show_folder(String.t()) :: :ok | {:error, term()}
  def show_folder(torrent_id) when is_binary(torrent_id) do
    with {:ok, hash} <- hash_from_hex_id(torrent_id),
         :ok <- ensure_darwin(),
         paths <- data_paths(hash),
         {:ok, cmd, args} <- open_command(hash, paths) do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ -> {:error, :open_failed}
      end
    end
  rescue
    ArgumentError -> {:error, :torrent_not_found}
  end

  @spec choose_download_folder() :: {:ok, Path.t()} | {:error, term()}
  def choose_download_folder do
    with :ok <- ensure_darwin(),
         {:ok, path} <- run_folder_picker() do
      validate_download_folder(path)
    end
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

  @spec hash_from_hex_id(String.t()) :: {:ok, Torrent.hash()} | {:error, :invalid_torrent}
  defp hash_from_hex_id(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, hash} when byte_size(hash) == 20 -> {:ok, hash}
      _ -> {:error, :invalid_torrent}
    end
  end

  @spec find_file(Torrent.hash(), non_neg_integer()) ::
          {:ok, FileRow.t()} | {:error, :file_not_found}
  defp find_file(hash, file_index) do
    case Enum.find(list_files(hash), &(&1.index == file_index)) do
      nil -> {:error, :file_not_found}
      file -> {:ok, file}
    end
  end

  @spec validate_playable(FileRow.t()) :: :ok | {:error, term()}
  defp validate_playable(file) do
    if playable_file?(file), do: :ok, else: {:error, :not_playable}
  end

  @spec safe_disk_path(String.t(), String.t()) :: {:ok, Path.t()} | {:error, :invalid_path}
  defp safe_disk_path(relative, torrent_id) when is_binary(relative) and is_binary(torrent_id) do
    base = Path.expand(TorrentCatalog.download_dir(torrent_id))
    path = Path.expand(Path.join(base, relative))

    if String.starts_with?(path, base <> "/") or path == base do
      {:ok, path}
    else
      {:error, :invalid_path}
    end
  end

  @spec run_folder_picker() :: {:ok, String.t()} | {:error, :cancelled}
  defp run_folder_picker do
    script = ~s'POSIX path of (choose folder with prompt "Choose download folder")'

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {path, 0} -> {:ok, String.trim(path)}
      _ -> {:error, :cancelled}
    end
  end

  @spec validate_download_folder(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  defp validate_download_folder(path) when is_binary(path) do
    folder = Path.expand(String.trim(path))

    cond do
      not File.dir?(folder) ->
        {:error, :invalid_folder}

      not writable_dir?(folder) ->
        {:error, :not_writable}

      true ->
        File.mkdir_p!(folder)
        {:ok, folder}
    end
  end

  @spec writable_dir?(Path.t()) :: boolean()
  defp writable_dir?(folder) do
    probe = Path.join(folder, ".elixir_torrent_write_probe")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      _ ->
        false
    end
  end

  @spec ensure_readable(Path.t()) :: :ok | {:error, :missing}
  defp ensure_readable(path) do
    if File.regular?(path), do: :ok, else: {:error, :missing}
  end

  @spec ensure_darwin() :: :ok | {:error, :unsupported_platform}
  defp ensure_darwin do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> {:error, :unsupported_platform}
    end
  end

  @spec data_paths(Torrent.hash()) :: [Path.t()]
  defp data_paths(hash) do
    hash
    |> Torrent.Removal.data_paths()
    |> Enum.map(&Path.expand/1)
  end

  @spec open_command(Torrent.hash(), [Path.t()]) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  defp open_command(hash, [path]) when is_binary(path) do
    if Torrent.file_count(hash) == 1 do
      reveal_in_finder(path)
    else
      open_directory(common_ancestor([path]))
    end
  end

  defp open_command(_hash, paths) when is_list(paths) and paths != [] do
    open_directory(common_ancestor(paths))
  end

  defp open_command(_hash, []), do: {:error, :missing}

  @spec reveal_in_finder(Path.t()) :: {:ok, String.t(), [String.t()]} | {:error, :missing}
  defp reveal_in_finder(path) do
    cond do
      File.regular?(path) -> {:ok, "open", ["-R", path]}
      File.dir?(path) -> {:ok, "open", [path]}
      File.dir?(Path.dirname(path)) -> {:ok, "open", [Path.dirname(path)]}
      true -> {:error, :missing}
    end
  end

  @spec open_directory(Path.t()) :: {:ok, String.t(), [String.t()]} | {:error, :missing}
  defp open_directory(dir) do
    if File.dir?(dir), do: {:ok, "open", [dir]}, else: {:error, :missing}
  end

  @spec common_ancestor([Path.t()]) :: Path.t()
  defp common_ancestor([first | rest]) do
    rest
    |> Enum.reduce(Path.split(first), &common_path_parts/2)
    |> Path.join()
  end

  @spec common_path_parts(Path.t(), [String.t()]) :: [String.t()]
  defp common_path_parts(path, acc) do
    acc
    |> Enum.zip(Path.split(path))
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map(fn {part, _} -> part end)
  end

  @spec status_string(Peer.status()) :: String.t()
  defp status_string(:seed), do: "Seeding"
  defp status_string(:connecting_to_peers), do: "Connecting"
  defp status_string(nil), do: "Idle"
  defp status_string(index) when is_integer(index), do: "Downloading"
end
