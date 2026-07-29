defmodule ElixirTorrentWebUI.TorrentCatalogTest do
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.{TorrentCatalog, UiState}

  test "default download folder is ~/Downloads not application data dir" do
    home = System.get_env("HOME") || File.cwd!()
    expected = Path.expand(Path.join(home, "Downloads"))

    assert UiState.default_download_folder() == expected
    refute UiState.default_download_folder() == TorrentCatalog.data_dir()
  end

  test "default content download dir is not the application data dir" do
    data = TorrentCatalog.data_dir()
    content = TorrentCatalog.default_content_download_dir()

    assert content != data
    assert content == UiState.get().download_folder
  end

  test "download_dir fallback for unknown torrent uses content dir not data dir" do
    unknown_id = String.duplicate("0", 40)

    assert TorrentCatalog.download_dir(unknown_id) ==
             TorrentCatalog.default_content_download_dir()

    refute TorrentCatalog.download_dir(unknown_id) == TorrentCatalog.data_dir()
  end

  test "legacy entries pointing at application data are remapped to the content folder" do
    hash = :crypto.strong_rand_bytes(20)
    id = Torrent.hex_encoded_hash(hash)
    torrent_path = Path.join(System.tmp_dir!(), "#{id}.torrent")
    File.write!(torrent_path, "")

    on_exit(fn ->
      TorrentCatalog.remove(id)
      File.rm(torrent_path)
    end)

    assert :ok =
             TorrentCatalog.register(
               hash,
               torrent_path,
               "legacy",
               TorrentCatalog.data_dir()
             )

    assert TorrentCatalog.download_dir(id) ==
             TorrentCatalog.default_content_download_dir()
  end
end
