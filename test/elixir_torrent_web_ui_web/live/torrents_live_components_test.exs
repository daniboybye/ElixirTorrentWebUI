defmodule ElixirTorrentWebUIWeb.TorrentsLiveComponentsTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElixirTorrentWebUI.Engine
  alias ElixirTorrentWebUIWeb.TorrentsLive

  setup do
    ElixirTorrentWebUI.Locale.put("en")
    :ok
  end

  test "renders expanded torrent rows and each media affordance" do
    torrent = torrent_row()

    html =
      render_component(&TorrentsLive.torrent_card/1,
        torrent: torrent,
        expanded: true,
        locale: "en"
      )

    assert html =~ ~s(id="torrent-#{torrent.id}-en")
    assert html =~ ~s(id="torrent-file-play-#{torrent.id}-0")
    assert html =~ ~s(id="torrent-file-image-#{torrent.id}-1")
    assert html =~ ~s(src="/media/#{torrent.id}/1/preview")
    assert html =~ "Remove"
    assert html =~ "Show Folder"
    assert html =~ "Seeding"
  end

  test "renders media, settings, and removal dialogs" do
    player =
      render_component(&TorrentsLive.media_player_modal/1,
        player: %{name: "movie.mp4", src: "/media/id/0"}
      )

    assert player =~ ~s(id="media-player-modal")
    assert player =~ ~s(src="/media/id/0")

    settings =
      render_component(&TorrentsLive.settings_dialog/1,
        open: true,
        locale: "en",
        download_folder: "/tmp/downloads",
        default_handler: %{supported: true, torrent: true, magnet: true},
        languages: [hd(ElixirTorrentWebUI.Languages.list())]
      )

    assert settings =~ ~s(id="settings-dialog")
    assert settings =~ ~s(id="settings-reset-statistics")
    assert settings =~ "/tmp/downloads"
    refute settings =~ ~s(id="settings-default-handler-banner")

    banner =
      render_component(&TorrentsLive.settings_dialog/1,
        open: true,
        locale: "en",
        download_folder: "/tmp/downloads",
        default_handler: %{supported: true, torrent: false, magnet: false},
        languages: [hd(ElixirTorrentWebUI.Languages.list())]
      )

    assert banner =~ ~s(id="settings-default-handler-banner")
    assert banner =~ ~s(id="settings-default-handler-set")
    assert banner =~ "Set as default"

    # The section has to stand out from the rest of the dialog, so it carries
    # the warning accent rather than the dialog's own primary tint.
    assert banner =~ "border-warning/60"
    assert banner =~ "bg-warning/15"
    assert banner =~ "hero-exclamation-triangle"
    refute banner =~ "bg-primary/10"

    removal =
      render_component(&TorrentsLive.remove_torrent_dialog/1,
        dialog: %{id: "id", name: "fixture", hash: <<0::160>>}
      )

    assert removal =~ ~s(id="remove-torrent-dialog")
    assert removal =~ "fixture"
    assert removal =~ "Remove Torrent + Data"
  end

  describe "default_handler_prompt/1" do
    test "greets a user whose machine points .torrent files somewhere else" do
      html =
        render_component(&TorrentsLive.default_handler_prompt/1,
          status: %{supported: true, torrent: false, magnet: false},
          dismissed: false
        )

      assert html =~ ~s(id="default-handler-prompt")
      assert html =~ ~s(id="default-handler-prompt-set")
      assert html =~ ~s(id="default-handler-prompt-dismiss")
      assert html =~ "Make ElixirTorrent Web your default torrent app"
      assert html =~ "hero-exclamation-triangle"
    end

    test "still appears when only one of the two handlers is ours" do
      html =
        render_component(&TorrentsLive.default_handler_prompt/1,
          status: %{supported: true, torrent: true, magnet: false},
          dismissed: false
        )

      assert html =~ ~s(id="default-handler-prompt")
    end

    test "stays out of the way once dismissed for the session" do
      html =
        render_component(&TorrentsLive.default_handler_prompt/1,
          status: %{supported: true, torrent: false, magnet: false},
          dismissed: true
        )

      refute html =~ ~s(id="default-handler-prompt")
    end

    test "never nags a user who is already the default" do
      html =
        render_component(&TorrentsLive.default_handler_prompt/1,
          status: %{supported: true, torrent: true, magnet: true},
          dismissed: false
        )

      refute html =~ ~s(id="default-handler-prompt")
    end

    test "stays hidden where the platform cannot answer the question" do
      html =
        render_component(&TorrentsLive.default_handler_prompt/1,
          status: %{supported: false, torrent: nil, magnet: nil},
          dismissed: false
        )

      refute html =~ ~s(id="default-handler-prompt")
    end
  end

  defp torrent_row do
    id = String.duplicate("A", 40)

    %Engine.TorrentRow{
      id: id,
      hash: <<0::160>>,
      name: "Fixture torrent",
      progress: 75.0,
      bytes_downloaded: 3_000,
      bytes_uploaded: 1_000,
      bytes_size: 4_000,
      down_kbps: 0,
      up_kbps: 12.5,
      peers: 3,
      status: "Seeding",
      eta_seconds: nil,
      file_count: 3,
      added_at: ~U[2026-07-29 00:00:00Z],
      files: [
        file_row(0, "movie.mp4", 10.0, false),
        file_row(1, "cover.jpg", 100.0, true),
        file_row(2, "notes.txt", 50.0, false)
      ]
    }
  end

  defp file_row(index, name, progress, complete?) do
    %Engine.FileRow{
      index: index,
      path: "folder/#{name}",
      name: name,
      length: 1_024,
      downloaded: if(complete?, do: 1_024, else: round(1_024 * progress / 100)),
      progress: progress,
      complete?: complete?
    }
  end
end
