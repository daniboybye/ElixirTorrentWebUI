defmodule ElixirTorrentWebUI.StatsStoreTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.StatsStore

  test "accumulate_counter adds delta from last seen value" do
    assert StatsStore.accumulate_counter(100, 150, 100) == {150, 150, true}
    assert StatsStore.accumulate_counter(100, 150, 150) == {100, 150, false}
  end

  test "accumulate_counter treats first observation as delta from zero" do
    assert StatsStore.accumulate_counter(1_000, 250, nil) == {1_250, 250, true}
    assert StatsStore.accumulate_counter(1_000, 0, nil) == {1_000, 0, false}
  end

  test "accumulate_counter handles session reset without subtracting" do
    assert StatsStore.accumulate_counter(5_000, 80, 500) == {5_080, 80, true}
    assert StatsStore.accumulate_counter(5_000, 0, 500) == {5_000, 0, false}
  end

  test "reset_state keeps current Engine counters as the new baseline" do
    hash = :crypto.strong_rand_bytes(20)

    state = %{
      total_downloaded: 5_000,
      total_uploaded: 2_000,
      last_seen: %{hash => {400, 100}},
      dirty?: false
    }

    assert %{
             total_downloaded: 0,
             total_uploaded: 0,
             last_seen: %{^hash => {450, 125}},
             dirty?: true
           } = StatsStore.reset_state(state, %{hash => {450, 125}})

    assert StatsStore.accumulate_counter(0, 450, 450) == {0, 450, false}
    assert StatsStore.accumulate_counter(0, 125, 125) == {0, 125, false}
  end
end
