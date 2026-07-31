defmodule ElixirTorrentWebUI.TorrentCatalog do
  @moduledoc false

  use GenServer

  alias ElixirTorrentWebUI.UiState

  @type entry :: %{
          id: String.t(),
          hash: binary(),
          torrent_path: Path.t(),
          name: String.t(),
          download_dir: Path.t(),
          added_at: DateTime.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec data_dir() :: Path.t()
  def data_dir do
    ElixirTorrentWebUI.DataDir.root()
  end

  @spec torrents_dir() :: Path.t()
  def torrents_dir do
    Path.join(data_dir(), "torrents")
  end

  @spec catalog_path() :: Path.t()
  def catalog_path do
    Path.join(data_dir(), "session/catalog.json")
  end

  @spec durable_torrent_path(String.t()) :: Path.t()
  def durable_torrent_path(id) do
    Path.join(torrents_dir(), "#{id}.torrent")
  end

  @spec register(binary(), Path.t(), String.t(), Path.t()) :: :ok
  def register(hash, torrent_path, name, download_dir) do
    GenServer.call(__MODULE__, {:register, hash, torrent_path, name, download_dir})
  end

  @spec remove(String.t()) :: :ok
  def remove(id) do
    GenServer.call(__MODULE__, {:remove, id})
  end

  @spec ordered_ids() :: [String.t()]
  def ordered_ids do
    GenServer.call(__MODULE__, :ordered_ids)
  end

  @spec entries() :: [entry()]
  def entries do
    GenServer.call(__MODULE__, :entries)
  end

  @spec download_dir(String.t()) :: Path.t()
  def download_dir(id) do
    case Map.get(entries_map(), id) do
      %{download_dir: dir} when is_binary(dir) -> dir
      _ -> default_content_download_dir()
    end
  end

  @doc false
  @spec default_content_download_dir() :: Path.t()
  def default_content_download_dir do
    UiState.get().download_folder
  catch
    :exit, _ -> UiState.default_download_folder()
  end

  @impl GenServer
  def init(_opts) do
    {:ok, load_from_disk()}
  end

  @impl GenServer
  def handle_call({:register, hash, torrent_path, name, download_dir}, _from, state) do
    id = Torrent.hex_encoded_hash(hash)
    download_dir = normalize_download_dir(download_dir)

    entry = %{
      id: id,
      hash: hash,
      torrent_path: torrent_path,
      name: name,
      download_dir: download_dir,
      added_at: DateTime.utc_now()
    }

    state =
      state
      |> Map.update!(:entries, &Map.put(&1, id, entry))
      |> update_in([:order], fn order -> [id | List.delete(order, id)] end)
      |> persist()

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:remove, id}, _from, state) do
    case Map.get(state.entries, id) do
      %{torrent_path: path} -> File.rm(path)
      _ -> :ok
    end

    state =
      state
      |> update_in([:entries], &Map.delete(&1, id))
      |> update_in([:order], &List.delete(&1, id))
      |> persist()

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:ordered_ids, _from, state), do: {:reply, state.order, state}

  @impl GenServer
  def handle_call(:entries, _from, state) do
    entries =
      state.order
      |> Enum.map(&Map.fetch!(state.entries, &1))

    {:reply, entries, state}
  end

  @impl GenServer
  def handle_call(:persist, _from, state) do
    {:reply, :ok, persist(state)}
  end

  @spec restore_torrents() :: :ok
  def restore_torrents do
    File.mkdir_p!(torrents_dir())

    for %{torrent_path: path, download_dir: download_dir} <- entries(),
        File.regular?(path) do
      _ = ElixirTorrent.download(path, download_dir: download_dir)
    end

    :ok
  end

  @spec persist_state() :: :ok
  def persist_state do
    ElixirTorrent.stop_all_and_serialize()
    GenServer.call(__MODULE__, :persist)
  end

  defp persist(state) do
    File.mkdir_p!(Path.dirname(catalog_path()))

    payload = %{
      "order" => state.order,
      "entries" =>
        state.entries
        |> Enum.map(fn {id, entry} ->
          {id,
           %{
             "torrent_path" => entry.torrent_path,
             "name" => entry.name,
             "download_dir" => entry.download_dir,
             "added_at" => DateTime.to_iso8601(entry.added_at)
           }}
        end)
        |> Map.new()
    }

    catalog_path()
    |> then(&File.write!(&1, Jason.encode!(payload)))

    state
  end

  defp load_from_disk do
    File.mkdir_p!(torrents_dir())

    case File.read(catalog_path()) do
      {:ok, body} ->
        decode_catalog(body)

      {:error, :enoent} ->
        %{order: [], entries: %{}}
    end
  end

  defp decode_catalog(body) do
    case Jason.decode(body) do
      {:ok, %{"order" => order, "entries" => entries}} ->
        %{order: order, entries: Map.new(entries, &decode_entry/1)}

      _ ->
        empty_catalog()
    end
  end

  defp decode_entry({id, entry}) do
    hash =
      case Base.decode16(id, case: :mixed) do
        {:ok, decoded} -> decoded
        :error -> nil
      end

    {id,
     %{
       id: id,
       hash: hash,
       torrent_path: entry["torrent_path"],
       name: entry["name"],
       download_dir: normalize_download_dir(entry["download_dir"]),
       added_at: parse_added_at(entry["added_at"])
     }}
  end

  defp empty_catalog, do: %{order: [], entries: %{}}

  defp parse_added_at(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_added_at(_), do: DateTime.utc_now()

  @spec entries_map() :: %{String.t() => entry()}
  defp entries_map do
    entries()
    |> Map.new(&{&1.id, &1})
  end

  @spec normalize_download_dir(Path.t()) :: Path.t()
  defp normalize_download_dir(dir) when is_binary(dir) do
    dir =
      dir
      |> Path.expand()
      |> remap_legacy_data_download_dir()

    File.mkdir_p!(dir)
    dir
  end

  @spec remap_legacy_data_download_dir(Path.t()) :: Path.t()
  defp remap_legacy_data_download_dir(dir) do
    if dir == Path.expand(data_dir()) do
      default_content_download_dir()
    else
      dir
    end
  end
end
