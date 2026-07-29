defmodule ElixirTorrentWebUI.StatsStoreResetTest do
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.StatsStore

  setup do
    original = :sys.get_state(StatsStore)

    on_exit(fn ->
      :sys.replace_state(StatsStore, fn _state -> original end)
      StatsStore.persist_state()
    end)

    :ok
  end

  test "reset clears and immediately persists lifetime totals" do
    :sys.replace_state(StatsStore, fn state ->
      %{state | total_downloaded: 9_000, total_uploaded: 4_000, dirty?: true}
    end)

    assert :ok = StatsStore.reset()
    assert StatsStore.get() == %{total_downloaded: 0, total_uploaded: 0}

    assert {:ok,
            %{
              "total_downloaded" => 0,
              "total_uploaded" => 0
            }} =
             ElixirTorrentWebUI.DataDir.root()
             |> Path.join("stats.json")
             |> File.read!()
             |> Jason.decode()
  end
end
