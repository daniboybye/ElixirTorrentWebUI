defmodule ElixirTorrentWebUI.Engine do
  @moduledoc """
  Thin adapter around the `:elixir_torrent` engine.

  UI code should depend on this module (not on engine internals).
  """

  use Gettext, backend: ElixirTorrentWebUIWeb.Gettext

  alias ElixirTorrentWebUI.{Media, OsIntegration, PathGuard, TorrentCatalog, UiState}

  require Logger

  @max_inline_image_bytes 50 * 1024 * 1024
  @min_play_progress_percent 1.0

  defmodule FileRow do
    @moduledoc false

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
    @moduledoc false

    @enforce_keys [
      :id,
      :hash,
      :name,
      :progress,
      :bytes_downloaded,
      :bytes_uploaded,
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
      :bytes_uploaded,
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
            bytes_uploaded: non_neg_integer(),
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

  defmodule AggregateStats do
    @moduledoc false
    defstruct bytes_downloaded: 0, bytes_uploaded: 0, down_kbps: 0, up_kbps: 0

    @type t :: %__MODULE__{
            bytes_downloaded: non_neg_integer(),
            bytes_uploaded: non_neg_integer(),
            down_kbps: number(),
            up_kbps: number()
          }
  end

  @spec aggregate_rates(list(TorrentRow.t())) :: AggregateStats.t()
  def aggregate_rates(torrents) when is_list(torrents) do
    Enum.reduce(torrents, %AggregateStats{}, fn torrent, acc ->
      %AggregateStats{
        down_kbps: acc.down_kbps + torrent.down_kbps,
        up_kbps: acc.up_kbps + torrent.up_kbps
      }
    end)
  end

  @spec aggregate_stats(list(TorrentRow.t())) :: AggregateStats.t()
  def aggregate_stats(torrents) when is_list(torrents) do
    rates = aggregate_rates(torrents)

    %AggregateStats{
      bytes_downloaded: Enum.sum(Enum.map(torrents, & &1.bytes_downloaded)),
      bytes_uploaded: Enum.sum(Enum.map(torrents, & &1.bytes_uploaded)),
      down_kbps: rates.down_kbps,
      up_kbps: rates.up_kbps
    }
  end

  @spec aggregate_stats() :: AggregateStats.t()
  def aggregate_stats, do: aggregate_stats(list_torrents())

  @spec valid_magnet?(String.t()) :: boolean()
  def valid_magnet?(uri) when is_binary(uri) do
    case Magnet.parse(String.trim(uri)) do
      {:ok, _} -> true
      _ -> false
    end
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

  @spec add_magnet(String.t()) :: {:ok, pid() | :fetching} | {:error, term()}
  def add_magnet(magnet_uri) when is_binary(magnet_uri) do
    uri = String.trim(magnet_uri)
    download_dir = UiState.get().download_folder

    Logger.debug("Engine.add_magnet: starting")

    result =
      case ElixirTorrent.download_magnet(uri, download_dir: download_dir) do
        {:ok, pid} ->
          register_magnet_download(pid)

        {:error, {:already_started, pid}} when is_pid(pid) ->
          register_magnet_download(pid)

        {:error, {:already_fetching, _pid}} ->
          {:ok, :fetching}

        other ->
          other
      end

    case result do
      {:ok, pid} ->
        Logger.debug("Engine.add_magnet: started pid=#{inspect(pid)}")

      {:error, reason} ->
        Logger.warning("Engine.add_magnet: failed reason=#{inspect(reason)}")
        remove_pending_on_fatal(uri, reason)
    end

    result
  end

  @fatal_magnet_errors [
    :timeout,
    :missing_trackers,
    :no_peers,
    :info_hash_mismatch,
    :metadata_unavailable
  ]

  defp remove_pending_on_fatal(uri, reason) when reason in @fatal_magnet_errors do
    :ok = ElixirTorrentWebUI.PendingMagnets.remove_by_uri(uri)
  end

  defp remove_pending_on_fatal(_uri, _reason), do: :ok

  @spec register_magnet_download(pid()) :: {:ok, pid()} | {:error, term()}
  defp register_magnet_download(pid) do
    with hash when is_binary(hash) <- Torrent.get_hash(pid),
         [name] <- Torrent.get(hash, [:name]) do
      id = Torrent.hex_encoded_hash(hash)
      dest = TorrentCatalog.durable_torrent_path(id)
      src = magnet_torrent_cache_path(id)

      File.mkdir_p!(TorrentCatalog.torrents_dir())

      if File.regular?(src) do
        File.cp!(src, dest)
      end

      download_dir = UiState.get().download_folder
      :ok = TorrentCatalog.register(hash, dest, name, download_dir)
      :ok = ElixirTorrentWebUI.PendingMagnets.remove(id)

      {:ok, pid}
    else
      _ -> {:error, :torrent_not_ready}
    end
  end

  @spec magnet_error_message(term()) :: String.t()
  def magnet_error_message(:invalid_scheme), do: gettext("Not a magnet link")
  def magnet_error_message(:missing_xt), do: gettext("Magnet link is missing the info hash (xt=)")
  def magnet_error_message(:invalid_btih), do: gettext("Invalid info hash in magnet link")
  def magnet_error_message(:invalid_magnet), do: gettext("Invalid magnet link")

  def magnet_error_message(:missing_trackers),
    do: gettext("Magnet has no tracker URLs and no peers were found via DHT")

  def magnet_error_message(:no_peers), do: gettext("Trackers returned no peers — try again later")
  def magnet_error_message(:timeout), do: gettext("Timed out fetching metadata from peers")

  def magnet_error_message(:metadata_unavailable),
    do: gettext("Could not download metadata from any peer")

  def magnet_error_message(:info_hash_mismatch),
    do: gettext("Downloaded metadata does not match the magnet hash")

  def magnet_error_message(:torrent_not_ready),
    do: gettext("Torrent process started but metadata is not ready yet")

  def magnet_error_message({:already_started, _}), do: gettext("Torrent is already downloading")

  def magnet_error_message(other),
    do: gettext("Failed to add magnet: %{reason}", reason: inspect(other))

  @spec magnet_torrent_cache_path(String.t()) :: Path.t()
  defp magnet_torrent_cache_path(id) do
    Path.join([System.tmp_dir!(), "elixir_torrent", "magnets", "#{id}.torrent"])
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

  @spec openable_image?(FileRow.t()) :: boolean()
  def openable_image?(%FileRow{complete?: complete?, name: name, path: path}) do
    complete? and (Media.image?(name) or Media.image?(path))
  end

  @spec previewable_image?(FileRow.t()) :: boolean()
  def previewable_image?(%FileRow{length: length, name: name, path: path} = file) do
    openable_image?(file) and length <= @max_inline_image_bytes and
      (Media.browser_image?(name) or Media.browser_image?(path))
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

  @spec resolve_image_preview(String.t(), non_neg_integer()) ::
          {:ok, %{name: String.t(), path: Path.t(), content_type: String.t()}}
          | {:error, term()}
  def resolve_image_preview(torrent_id, file_index) do
    with {:ok, hash} <- hash_from_hex_id(torrent_id),
         {:ok, file} <- find_file(hash, file_index),
         true <- previewable_image?(file),
         {:ok, path} <- safe_disk_path(file.path, torrent_id),
         :ok <- ensure_readable(path),
         {:ok, content_type} <- image_content_type(file) do
      {:ok, %{name: file.name, path: path, content_type: content_type}}
    else
      false -> {:error, :not_previewable}
      other -> other
    end
  end

  @spec open_image(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def open_image(torrent_id, file_index) do
    with {:ok, hash} <- hash_from_hex_id(torrent_id),
         {:ok, file} <- find_file(hash, file_index),
         true <- openable_image?(file),
         {:ok, path} <- safe_disk_path(file.path, torrent_id),
         :ok <- ensure_readable(path) do
      OsIntegration.open_file(path)
    else
      false -> {:error, :not_openable}
      other -> other
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

    [name, speed, downloaded, uploaded, size, peer_status, added_at] =
      Torrent.get(hash, [
        :name,
        :speed,
        :downloaded,
        :uploaded,
        :bytes_size,
        :peer_status,
        :added_at
      ])

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
      bytes_uploaded: uploaded,
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
  catch
    :exit, _ -> {:error, :torrent_not_found}
  end

  @spec validate_playable(FileRow.t()) :: :ok | {:error, term()}
  defp validate_playable(file) do
    if playable_file?(file), do: :ok, else: {:error, :not_playable}
  end

  defp image_content_type(file) do
    if Media.image?(file.name) do
      Media.image_content_type(file.name)
    else
      Media.image_content_type(file.path)
    end
  end

  @spec safe_disk_path(String.t(), String.t()) :: {:ok, Path.t()} | {:error, :invalid_path}
  defp safe_disk_path(relative, torrent_id) when is_binary(relative) and is_binary(torrent_id) do
    torrent_id
    |> TorrentCatalog.download_dir()
    |> PathGuard.safe_join(relative)
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
