defmodule ElixirTorrentWebUI.PendingMagnets do
  @moduledoc false

  use GenServer

  alias ElixirTorrentWebUI.TorrentCatalog

  require Logger

  # Match engine Magnet.Fetcher max lifetime — evict UI rows that would never
  # succeed so boot resume_on_boot does not respawn month-old dead fetches.
  @max_pending_age_sec 24 * 60 * 60

  @type entry :: %{
          id: String.t(),
          uri: String.t(),
          name: String.t() | nil,
          stage: String.t(),
          added_at: DateTime.t(),
          round: non_neg_integer(),
          peers_known: non_neg_integer(),
          peers_tried: non_neg_integer(),
          error: String.t() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec path() :: Path.t()
  def path do
    Path.join(TorrentCatalog.data_dir(), "session/pending_magnets.json")
  end

  @spec register(String.t()) :: :ok
  def register(magnet_uri) when is_binary(magnet_uri) do
    GenServer.call(__MODULE__, {:register, String.trim(magnet_uri)})
  end

  @spec remove(String.t()) :: :ok
  def remove(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:remove, id})
  end

  @spec remove_by_uri(String.t()) :: :ok
  def remove_by_uri(magnet_uri) when is_binary(magnet_uri) do
    GenServer.call(__MODULE__, {:remove_by_uri, String.trim(magnet_uri)})
  end

  @spec resume_on_boot() :: :ok
  def resume_on_boot do
    GenServer.call(__MODULE__, :resume_on_boot)
  end

  @spec entries() :: [entry()]
  def entries do
    GenServer.call(__MODULE__, :entries)
  end

  @impl GenServer
  def init(_opts) do
    state =
      load_from_disk()
      |> evict_stale()

    count = map_size(state.entries)

    if count > 0 do
      Logger.debug("[magnet_pending] restored count=#{count} from disk")
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register, uri}, _from, state) do
    case Magnet.parse(uri) do
      {:ok, %Magnet{} = magnet} ->
        id = Torrent.hex_encoded_hash(magnet.hash)

        entry = %{
          id: id,
          uri: uri,
          name: magnet.display_name,
          stage: "fetching",
          added_at: DateTime.utc_now(),
          round: 0,
          peers_known: 0,
          peers_tried: 0,
          error: nil
        }

        state =
          state
          |> put_entry(entry)
          |> persist()

        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warning("[magnet_pending] register_skip reason=#{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove, id}, _from, state) do
    {:reply, :ok, drop_id(state, id) |> persist()}
  end

  def handle_call({:remove_by_uri, uri}, _from, state) do
    id =
      case Magnet.parse(uri) do
        {:ok, %Magnet{} = magnet} -> Torrent.hex_encoded_hash(magnet.hash)
        _ -> nil
      end

    state =
      if is_binary(id) do
        drop_id(state, id)
      else
        state
      end

    {:reply, :ok, persist(state)}
  end

  def handle_call(:resume_on_boot, _from, state) do
    state = evict_stale(state)

    state.order
    |> Enum.map(&Map.fetch!(state.entries, &1))
    |> Enum.each(fn entry ->
      Task.start(fn ->
        Logger.debug("[magnet_pending] boot_restart hash=#{entry.id}")
        _ = ElixirTorrentWebUI.Engine.add_magnet(entry.uri)
      end)
    end)

    {:reply, :ok, state}
  end

  def handle_call(:entries, _from, state) do
    entries =
      state.order
      |> Enum.map(&Map.fetch!(state.entries, &1))

    {:reply, entries, state}
  end

  defp put_entry(state, entry) do
    state
    |> update_in([:entries], &Map.put(&1, entry.id, entry))
    |> update_in([:order], fn order -> [entry.id | List.delete(order, entry.id)] end)
  end

  defp drop_id(state, id) do
    state
    |> update_in([:entries], &Map.delete(&1, id))
    |> update_in([:order], &List.delete(&1, id))
  end

  defp persist(state) do
    File.mkdir_p!(Path.dirname(path()))

    payload = %{
      "magnets" =>
        state.order
        |> Enum.map(fn id ->
          entry = Map.fetch!(state.entries, id)

          %{
            "id" => entry.id,
            "uri" => entry.uri,
            "name" => entry.name,
            "stage" => entry.stage,
            "added_at" => DateTime.to_iso8601(entry.added_at),
            "round" => entry.round,
            "peers_known" => entry.peers_known,
            "peers_tried" => entry.peers_tried,
            "fetch_status" => "fetching metadata",
            "error" => entry.error
          }
        end)
    }

    File.write!(path(), Jason.encode!(payload))
    state
  end

  defp load_from_disk do
    case File.read(path()) do
      {:ok, body} -> decode(body)
      {:error, :enoent} -> empty_state()
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"magnets" => magnets}} when is_list(magnets) -> decode_magnets(magnets)
      _ -> empty_state()
    end
  end

  defp decode_magnets(magnets) do
    entries =
      magnets
      |> Enum.flat_map(&decode_magnet/1)
      |> Map.new()

    order =
      magnets
      |> Enum.map(& &1["id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %{order: order, entries: entries}
  end

  defp decode_magnet(%{"id" => id, "uri" => uri} = raw)
       when is_binary(id) and is_binary(uri) do
    [
      {id,
       %{
         id: id,
         uri: uri,
         name: raw["name"],
         stage: raw["stage"] || "fetching",
         added_at: parse_time(raw["added_at"]),
         round: raw["round"] || 0,
         peers_known: raw["peers_known"] || 0,
         peers_tried: raw["peers_tried"] || 0,
         error: raw["error"]
       }}
    ]
  end

  defp decode_magnet(_), do: []

  defp empty_state, do: %{order: [], entries: %{}}

  defp parse_time(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(_), do: DateTime.utc_now()

  defp evict_stale(%{order: order, entries: entries} = state) do
    now = DateTime.utc_now()

    {fresh_order, fresh_entries, evicted} =
      Enum.reduce(order, {[], %{}, []}, fn id, {ord, ents, gone} ->
        evict_entry(Map.fetch(entries, id), id, now, {ord, ents, gone})
      end)

    if evicted != [] do
      persist(%{order: Enum.reverse(fresh_order), entries: fresh_entries})
    end

    %{state | order: Enum.reverse(fresh_order), entries: fresh_entries}
  end

  defp evict_entry(:error, _id, _now, acc), do: acc

  defp evict_entry({:ok, entry}, id, now, {order, entries, evicted}) do
    age_sec = DateTime.diff(now, entry.added_at, :second)

    if age_sec >= @max_pending_age_sec do
      Logger.warning(
        "[magnet_pending] evict_stale hash=#{id} age_sec=#{age_sec} max_sec=#{@max_pending_age_sec}"
      )

      {order, entries, [id | evicted]}
    else
      {[id | order], Map.put(entries, id, entry), evicted}
    end
  end
end
