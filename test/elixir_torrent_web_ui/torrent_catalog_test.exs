defmodule ElixirTorrentWebUI.TorrentCatalogTest do
  use ExUnit.Case, async: false

  alias ElixirTorrentWebUI.{TorrentCatalog, UiState}

  test "default download folder is the user's Downloads, not the application data dir" do
    # Which environment variable names the home directory is per-platform, and
    # `default_download_folder/2` is pinned for each of them in UiStateTest.
    # What belongs here is only that the zero-arity wrapper routes through the
    # host it is actually running on: it used to be checked against a hardcoded
    # $HOME, which is unset on Windows, so the assertion compared %USERPROFILE%
    # \Downloads against a Downloads folder under the checkout.
    expected = UiState.default_download_folder(:os.type(), &System.get_env/1)

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
