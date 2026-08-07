defmodule ElixirTorrentWebUI.IssueReportTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUI.IssueReport

  defp fixed_config, do: fn -> [repo: "acme/webui", labels: ["bug", "in-app-report"]] end

  defp base_app_context do
    %{version: "0.2.0", os: "unix/darwin", locale: "bg", theme: "dark"}
  end

  describe "categories/0 and category/1" do
    test "returns the canonical list and looks up by id" do
      cats = IssueReport.categories()

      assert length(cats) == 8
      assert Enum.all?(cats, &Map.has_key?(&1, :id))
      assert Enum.all?(cats, &Map.has_key?(&1, :label))

      assert IssueReport.category("no-peers").label == "No peers are found"
      assert IssueReport.category("unknown") == nil
      assert IssueReport.category(nil) == nil
    end
  end

  describe "build/1" do
    test "normalises blanks to nil and drops unknown categories" do
      report =
        IssueReport.build(%{
          category: "not-a-category",
          description: "  \n  ",
          magnet: "   ",
          torrent_summary: nil,
          torrent_context: nil,
          app_context: base_app_context()
        })

      assert report.category == nil
      assert report.description == ""
      assert report.magnet == nil
      assert report.app_context == base_app_context()
    end

    test "keeps a valid category and trims strings" do
      report =
        IssueReport.build(%{
          category: "no-peers",
          description: "  It says peers=0.  ",
          magnet: " magnet:?xt=urn:btih:abc "
        })

      assert report.category == "no-peers"
      assert report.description == "It says peers=0."
      assert report.magnet == "magnet:?xt=urn:btih:abc"
    end
  end

  describe "title/1" do
    test "labels an uncategorised, torrent-less report clearly" do
      report = IssueReport.build(%{})
      assert IssueReport.title(report) == "[Report] Uncategorised"
    end

    test "combines category label and torrent name from the summary" do
      report =
        IssueReport.build(%{
          category: "stuck",
          torrent_summary: %{
            name: "Ubuntu 22.04.iso",
            info_hash_hex: "aaaa",
            size_bytes: 100,
            magnet: nil
          }
        })

      assert IssueReport.title(report) ==
               "[Report] Torrent is stuck or looping — Ubuntu 22.04.iso"
    end

    test "prefers the running torrent's context name over an attached summary" do
      report =
        IssueReport.build(%{
          category: "no-peers",
          torrent_summary: %{
            name: "Attached",
            info_hash_hex: "aa",
            size_bytes: 0,
            magnet: nil
          },
          torrent_context: %{
            name: "Running torrent",
            info_hash_hex: "bb",
            progress_percent: 50.0,
            status: "Downloading",
            peers: 3,
            down_kbps: 100,
            up_kbps: 10,
            bytes_downloaded: 500,
            bytes_size: 1_000
          }
        })

      assert IssueReport.title(report) ==
               "[Report] No peers are found — Running torrent"
    end

    test "truncates very long torrent names" do
      long_name = String.duplicate("A", 200)

      report =
        IssueReport.build(%{
          torrent_summary: %{name: long_name, info_hash_hex: "cc", size_bytes: 0, magnet: nil}
        })

      title = IssueReport.title(report)

      assert String.length(title) < 200
      assert String.ends_with?(title, "…")
    end
  end

  describe "body/1" do
    test "includes description, category and app context" do
      report =
        IssueReport.build(%{
          category: "crash",
          description: "It crashed at launch.\nDialog appeared.",
          app_context: base_app_context()
        })

      body = IssueReport.body(report)

      assert body =~ "## What went wrong"
      assert body =~ "> It crashed at launch."
      assert body =~ "> Dialog appeared."
      assert body =~ "## Category"
      assert body =~ "- App crashed or froze"
      assert body =~ "## App context"
      assert body =~ "**Version**: 0.2.0"
      assert body =~ "**OS**: unix/darwin"
      assert body =~ "**Locale**: bg"
      assert body =~ "**Theme**: dark"
      refute body =~ "## Attached torrent"
      refute body =~ "## Torrent context"
    end

    test "renders the attached torrent summary when present" do
      report =
        IssueReport.build(%{
          torrent_summary: %{
            name: "Ubuntu.iso",
            info_hash_hex: "abc123",
            size_bytes: 4_096,
            magnet: "magnet:?xt=urn:btih:abc123&dn=Ubuntu.iso"
          }
        })

      body = IssueReport.body(report)

      assert body =~ "## Attached torrent"
      assert body =~ "**Name**: Ubuntu.iso"
      assert body =~ "**Info hash**: `abc123`"
      assert body =~ "**Size**: 4096 bytes"
      assert body =~ "**Magnet**: `magnet:?xt=urn:btih:abc123&dn=Ubuntu.iso`"
    end

    test "renders the running torrent context when opened from a torrent item" do
      report =
        IssueReport.build(%{
          torrent_context: %{
            name: "Running",
            info_hash_hex: "deadbeef",
            progress_percent: 42.5,
            status: "Downloading",
            peers: 7,
            down_kbps: 128.0,
            up_kbps: 12.5,
            bytes_downloaded: 1_000,
            bytes_size: 10_000
          }
        })

      body = IssueReport.body(report)

      assert body =~ "## Torrent context (auto-collected)"
      assert body =~ "**Name**: Running"
      assert body =~ "**Info hash**: `deadbeef`"
      assert body =~ "**Status**: Downloading"
      assert body =~ "**Progress**: 42.5%"
      assert body =~ "**Peers**: 7"
      assert body =~ "↓ 128.0"
      assert body =~ "↑ 12.5"
      assert body =~ "1000 / 10000"
    end

    test "falls back to a placeholder when the description is empty" do
      body = IssueReport.build(%{}) |> IssueReport.body()
      assert body =~ "_No description provided._"
    end
  end

  describe "url/2" do
    test "encodes title, body, and labels into the GitHub Issues new URL" do
      report =
        IssueReport.build(%{
          category: "stuck",
          description: "Обикновено засича на 99%",
          app_context: base_app_context()
        })

      url = IssueReport.url(report, fixed_config())

      assert String.starts_with?(url, "https://github.com/acme/webui/issues/new?")
      assert url =~ "labels=bug%2Cin-app-report"
      assert url =~ "title=%5BReport%5D+Torrent+is+stuck+or+looping"
      assert url =~ URI.encode_www_form("Обикновено засича на 99%")
    end

    test "handles missing labels gracefully" do
      report = IssueReport.build(%{})
      url = IssueReport.url(report, fn -> [repo: "a/b"] end)

      assert String.starts_with?(url, "https://github.com/a/b/issues/new?")
      refute url =~ "labels="
    end
  end
end
