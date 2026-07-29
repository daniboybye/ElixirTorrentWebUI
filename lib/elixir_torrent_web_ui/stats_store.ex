defmodule ElixirTorrentWebUI.StatsStore do
  @moduledoc false

  use GenServer

  @tick_ms 1_500
  @persist_ms 5_000

  @type totals :: %{
          total_downloaded: non_neg_integer(),
          total_uploaded: non_neg_integer()
        }

  @type counters :: %{binary() => {non_neg_integer(), non_neg_integer()}}

  @type state :: %{
          total_downloaded: non_neg_integer(),
          total_uploaded: non_neg_integer(),
          last_seen: counters(),
          dirty?: boolean()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get() :: totals()
  def get, do: GenServer.call(__MODULE__, :get)

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec persist_state() :: :ok
  def persist_state, do: GenServer.call(__MODULE__, :persist)

  @doc false
  @spec accumulate_counter(non_neg_integer(), non_neg_integer(), nil | non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), boolean()}
  def accumulate_counter(total, current, last_seen)
      when is_integer(total) and total >= 0 and is_integer(current) and current >= 0 do
    cond do
      is_nil(last_seen) ->
        {total + current, current, current > 0}

      current >= last_seen ->
        delta = current - last_seen
        {total + delta, current, delta > 0}

      true ->
        {total + current, current, current > 0}
    end
  end

  @doc false
  @spec reset_state(state(), counters()) :: state()
  def reset_state(state, last_seen) do
    %{
      state
      | total_downloaded: 0,
        total_uploaded: 0,
        last_seen: last_seen,
        dirty?: true
    }
  end

  @impl true
  def init(_opts) do
    state = load_from_disk()
    schedule_tick()
    schedule_persist()
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, totals(state), state}
  end

  def handle_call(:reset, _from, state) do
    state =
      state
      |> reset_state(snapshot_counters())
      |> persist()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:persist, _from, state) do
    {:reply, :ok, persist(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, tick(state)}
  end

  @impl true
  def handle_info(:persist, state) do
    schedule_persist()
    {:noreply, maybe_persist(state)}
  end

  @impl true
  def terminate(_reason, state) do
    _ = persist(state)
    :ok
  end

  @spec tick(state()) :: state()
  defp tick(%{total_downloaded: td, total_uploaded: tu, last_seen: last_seen} = state) do
    active = Torrents.list()

    {td, tu, last_seen, dirty?} =
      Enum.reduce(active, {td, tu, last_seen, false}, fn hash, {td, tu, ls, dirty} ->
        [down, up] = Torrent.get(hash, [:downloaded, :uploaded])
        {down_last, up_last} = Map.get(ls, hash, {nil, nil})

        {td, new_down, down_dirty?} = accumulate_counter(td, down, down_last)
        {tu, new_up, up_dirty?} = accumulate_counter(tu, up, up_last)

        ls = Map.put(ls, hash, {new_down, new_up})
        {td, tu, ls, dirty or down_dirty? or up_dirty?}
      end)

    last_seen = Map.take(last_seen, active)

    %{state | total_downloaded: td, total_uploaded: tu, last_seen: last_seen, dirty?: dirty?}
  end

  @spec snapshot_counters() :: counters()
  defp snapshot_counters do
    Torrents.list()
    |> Map.new(fn hash ->
      [downloaded, uploaded] = Torrent.get(hash, [:downloaded, :uploaded])
      {hash, {downloaded, uploaded}}
    end)
  end

  @spec totals(state()) :: totals()
  defp totals(state) do
    %{
      total_downloaded: state.total_downloaded,
      total_uploaded: state.total_uploaded
    }
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  @spec schedule_persist() :: reference()
  defp schedule_persist, do: Process.send_after(self(), :persist, @persist_ms)

  @spec maybe_persist(state()) :: state()
  defp maybe_persist(%{dirty?: false} = state), do: state
  defp maybe_persist(state), do: persist(state)

  @spec persist(state()) :: state()
  defp persist(state) do
    File.mkdir_p!(Path.dirname(path()))

    payload = %{
      "total_downloaded" => state.total_downloaded,
      "total_uploaded" => state.total_uploaded
    }

    path() |> then(&File.write!(&1, Jason.encode!(payload)))
    %{state | dirty?: false}
  end

  @spec path() :: Path.t()
  defp path do
    Path.join(ElixirTorrentWebUI.DataDir.root(), "stats.json")
  end

  @spec load_from_disk() :: state()
  defp load_from_disk do
    case File.read(path()) do
      {:ok, body} -> decode(body)
      {:error, :enoent} -> default()
      _ -> default()
    end
  end

  @spec decode(String.t()) :: state()
  defp decode(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, total_downloaded, total_uploaded} <- decode_fields(decoded) do
      %{
        total_downloaded: total_downloaded,
        total_uploaded: total_uploaded,
        last_seen: %{},
        dirty?: false
      }
    else
      _ -> default()
    end
  end

  @spec decode_fields(map()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  defp decode_fields(%{"total_downloaded" => down, "total_uploaded" => up})
       when is_integer(down) and down >= 0 and is_integer(up) and up >= 0 do
    {:ok, down, up}
  end

  defp decode_fields(_), do: :error

  @spec default() :: state()
  defp default do
    %{
      total_downloaded: 0,
      total_uploaded: 0,
      last_seen: %{},
      dirty?: false
    }
  end
end
