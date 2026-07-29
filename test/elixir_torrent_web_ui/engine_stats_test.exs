defmodule ElixirTorrentWebUI.EngineStatsTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.Engine

  test "aggregate_stats sums transfer counters and rates" do
    torrents = [
      torrent_row(1_024, 512, 10.5, 2.0),
      torrent_row(2_048, 256, 4.5, 1.5)
    ]

    assert %Engine.AggregateStats{
             bytes_downloaded: 3_072,
             bytes_uploaded: 768,
             down_kbps: 15.0,
             up_kbps: 3.5
           } = Engine.aggregate_stats(torrents)
  end

  defp torrent_row(downloaded, uploaded, down_kbps, up_kbps) do
    %Engine.TorrentRow{
      id: Base.encode16(:crypto.strong_rand_bytes(20)),
      hash: :crypto.strong_rand_bytes(20),
      name: "fixture",
      progress: 0.0,
      bytes_downloaded: downloaded,
      bytes_uploaded: uploaded,
      bytes_size: 10_000,
      down_kbps: down_kbps,
      up_kbps: up_kbps,
      peers: 0,
      status: "Idle",
      eta_seconds: nil,
      file_count: 0,
      added_at: nil,
      files: []
    }
  end
end
