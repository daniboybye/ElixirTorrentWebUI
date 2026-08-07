defmodule ElixirTorrentWebUI.TorrentSummaryTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.TorrentSummary

  # Bento's map encoder produces a canonical bencoded dictionary — same
  # bytes on every run — so `parse_file!/1` yields the same info hash we
  # compute below. That keeps the test hermetic without a checked-in fixture.
  defp single_file_torrent_bytes(name, length) do
    info = %{
      "length" => length,
      "name" => name,
      "piece length" => 16_384,
      "pieces" => :binary.copy(<<0>>, 20)
    }

    meta = %{
      "announce" => "http://tracker.example/announce",
      "info" => info
    }

    {Bento.encode!(meta), info}
  end

  defp multi_file_torrent_bytes(name, file_lengths) do
    info = %{
      "files" =>
        Enum.map(file_lengths, fn {path, len} ->
          %{"length" => len, "path" => [path]}
        end),
      "name" => name,
      "piece length" => 16_384,
      "pieces" => :binary.copy(<<0>>, 20)
    }

    Bento.encode!(%{
      "announce" => "http://tracker.example/announce",
      "info" => info
    })
  end

  defp expected_info_hash_hex(info) do
    info
    |> Bento.encode!()
    |> then(&:crypto.hash(:sha, &1))
    |> Base.encode16()
  end

  defp write_tmp(bytes) do
    dir = System.tmp_dir!()
    filename = "test-#{System.unique_integer([:positive])}.torrent"
    path = Path.join(dir, filename)
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "reads name, hash, and single-file size from a valid v1 torrent" do
    {bytes, info} = single_file_torrent_bytes("hello.txt", 4_096)
    path = write_tmp(bytes)

    assert {:ok, summary} = TorrentSummary.from_path(path)
    assert summary.name == "hello.txt"
    assert summary.size_bytes == 4_096
    assert summary.info_hash_hex == expected_info_hash_hex(info)
    assert summary.magnet =~ "magnet:?xt=urn:btih:"
    assert summary.magnet =~ String.downcase(summary.info_hash_hex)
    assert summary.magnet =~ "dn=hello.txt"
  end

  test "sums the file lengths for a multi-file torrent" do
    bytes = multi_file_torrent_bytes("bundle", [{"a.txt", 100}, {"b.txt", 200}])
    path = write_tmp(bytes)

    assert {:ok, summary} = TorrentSummary.from_path(path)
    assert summary.name == "bundle"
    assert summary.size_bytes == 300
  end

  test "returns {:error, _} when the file is not a valid torrent" do
    path = write_tmp("not bencoded")
    assert {:error, _} = TorrentSummary.from_path(path)
  end

  test "magnet_uri/2 builds a canonical lowercase btih magnet" do
    magnet = TorrentSummary.magnet_uri("ABCDEF", "My File.iso")
    assert magnet == "magnet:?xt=urn:btih:abcdef&dn=My+File.iso"
  end

  test "total_size/1 handles missing keys" do
    assert TorrentSummary.total_size(%{}) == nil
    assert TorrentSummary.total_size(%{"info" => %{"length" => 42}}) == 42

    assert TorrentSummary.total_size(%{
             "info" => %{"files" => [%{"length" => 1}, %{"length" => 2}]}
           }) == 3

    # Missing length in one entry -> bail.
    assert TorrentSummary.total_size(%{"info" => %{"files" => [%{"length" => 1}, %{"foo" => 2}]}}) ==
             nil
  end
end
