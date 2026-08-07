defmodule ElixirTorrentWebUI.IssueReport do
  @moduledoc false

  # Turns the in-app report form into a pre-populated GitHub Issues URL.
  # Everything here is pure — the module never talks to the network, never
  # opens a browser, never writes files. The LiveView (or a test) is
  # responsible for handing the resulting URL to the OS.

  @type category_id :: String.t()

  @type torrent_summary :: %{
          required(:name) => String.t(),
          required(:info_hash_hex) => String.t(),
          required(:size_bytes) => non_neg_integer() | nil,
          required(:magnet) => String.t() | nil
        }

  @type torrent_context :: %{
          required(:name) => String.t(),
          required(:info_hash_hex) => String.t(),
          required(:progress_percent) => float() | nil,
          required(:status) => String.t() | nil,
          required(:peers) => non_neg_integer() | nil,
          required(:down_kbps) => number() | nil,
          required(:up_kbps) => number() | nil,
          required(:bytes_downloaded) => non_neg_integer() | nil,
          required(:bytes_size) => non_neg_integer() | nil
        }

  @type app_context :: %{
          required(:version) => String.t(),
          required(:os) => String.t(),
          required(:locale) => String.t(),
          required(:theme) => String.t()
        }

  @type t :: %__MODULE__{
          category: category_id() | nil,
          description: String.t(),
          magnet: String.t() | nil,
          torrent_summary: torrent_summary() | nil,
          torrent_context: torrent_context() | nil,
          app_context: app_context() | nil
        }

  defstruct category: nil,
            description: "",
            magnet: nil,
            torrent_summary: nil,
            torrent_context: nil,
            app_context: nil

  @categories [
    %{id: "not-downloading", label: "Torrent is not downloading"},
    %{id: "stuck", label: "Torrent is stuck or looping"},
    %{id: "no-peers", label: "No peers are found"},
    %{id: "metadata", label: "Metadata never arrives"},
    %{id: "playback", label: "Play or preview does not work"},
    %{id: "crash", label: "App crashed or froze"},
    %{id: "ui", label: "UI glitch or wrong translation"},
    %{id: "other", label: "Something else"}
  ]

  @spec categories() :: [%{id: String.t(), label: String.t()}]
  def categories, do: @categories

  @spec category(category_id()) :: %{id: String.t(), label: String.t()} | nil
  def category(id) when is_binary(id),
    do: Enum.find(@categories, fn %{id: candidate} -> candidate == id end)

  def category(_), do: nil

  @doc """
  Build a normalized report struct from a loose params map.

  Empty / blank strings are normalised to `nil`; unknown categories are
  discarded rather than round-tripped, so the URL never carries junk.
  """
  @spec build(map()) :: t()
  def build(params) when is_map(params) do
    %__MODULE__{
      category: normalize_category(Map.get(params, :category)),
      description:
        params
        |> Map.get(:description, "")
        |> normalize_string(),
      magnet:
        params
        |> Map.get(:magnet)
        |> normalize_optional_string(),
      torrent_summary: Map.get(params, :torrent_summary),
      torrent_context: Map.get(params, :torrent_context),
      app_context: Map.get(params, :app_context)
    }
  end

  @doc "Short human-readable title used both in-app and in the GitHub issue."
  @spec title(t()) :: String.t()
  def title(%__MODULE__{} = report) do
    label = category_label(report.category)

    subject =
      cond do
        report.torrent_context && report.torrent_context.name != "" ->
          report.torrent_context.name

        report.torrent_summary && report.torrent_summary.name != "" ->
          report.torrent_summary.name

        true ->
          nil
      end

    case {label, subject} do
      {label, nil} -> "[Report] #{label}"
      {label, name} -> "[Report] #{label} — #{truncate(name, 80)}"
    end
  end

  @doc "Markdown body for the GitHub issue."
  @spec body(t()) :: String.t()
  def body(%__MODULE__{} = report) do
    [
      "## What went wrong",
      description_section(report),
      "## Category",
      "- #{category_label(report.category)}",
      torrent_summary_section(report),
      torrent_context_section(report),
      app_context_section(report),
      "---",
      "_Sent via the in-app bug report form._"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Build the full https://github.com/…/issues/new URL with title/body/labels
  URL-encoded. `config_fun` lets tests inject a repo/labels payload without
  going through Application.get_env.
  """
  @spec url(t(), (-> keyword())) :: String.t()
  def url(report, config_fun \\ &default_config/0)

  def url(%__MODULE__{} = report, config_fun) when is_function(config_fun, 0) do
    config = config_fun.()
    repo = Keyword.fetch!(config, :repo)

    labels =
      config
      |> Keyword.get(:labels, [])
      |> Enum.map(&to_string/1)

    query =
      [
        {"title", title(report)},
        {"body", body(report)},
        {"labels", Enum.join(labels, ",")}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    "https://github.com/#{repo}/issues/new?#{query}"
  end

  @spec default_config() :: keyword()
  def default_config,
    do: Application.get_env(:elixir_torrent_web_ui, :issue_report, repo: "", labels: [])

  # -- private ----------------------------------------------------------------

  defp normalize_string(nil), do: ""
  defp normalize_string(s) when is_binary(s), do: String.trim(s)

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_category(nil), do: nil

  defp normalize_category(id) when is_binary(id) do
    if category(id), do: id, else: nil
  end

  defp category_label(nil), do: "Uncategorised"

  defp category_label(id) when is_binary(id) do
    case category(id) do
      %{label: label} -> label
      nil -> "Uncategorised"
    end
  end

  defp description_section(%__MODULE__{description: ""}), do: "_No description provided._"

  defp description_section(%__MODULE__{description: text}) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp torrent_summary_section(%__MODULE__{
         torrent_summary: nil,
         magnet: nil
       }),
       do: nil

  defp torrent_summary_section(%__MODULE__{torrent_summary: summary, magnet: magnet}) do
    lines =
      [
        {"Name", get_in(summary, [:name])},
        {"Info hash", info_hash_backticked(get_in(summary, [:info_hash_hex]))},
        {"Size", size_bytes_label(get_in(summary, [:size_bytes]))},
        {"Magnet", magnet_line(magnet || get_in(summary, [:magnet]))}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "- **#{k}**: #{v}" end)

    if lines == [] do
      nil
    else
      "## Attached torrent\n" <> Enum.join(lines, "\n")
    end
  end

  defp torrent_context_section(%__MODULE__{torrent_context: nil}), do: nil

  defp torrent_context_section(%__MODULE__{torrent_context: ctx}) do
    lines =
      [
        {"Name", ctx.name},
        {"Info hash", info_hash_backticked(ctx.info_hash_hex)},
        {"Status", ctx.status},
        {"Progress", percent_label(ctx.progress_percent)},
        {"Peers", peers_label(ctx.peers)},
        {"Down / Up (kbps)", rate_label(ctx.down_kbps, ctx.up_kbps)},
        {"Downloaded / Size", size_pair_label(ctx.bytes_downloaded, ctx.bytes_size)}
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "- **#{k}**: #{v}" end)

    if lines == [] do
      nil
    else
      "## Torrent context (auto-collected)\n" <> Enum.join(lines, "\n")
    end
  end

  defp app_context_section(%__MODULE__{app_context: nil}), do: nil

  defp app_context_section(%__MODULE__{app_context: app}) do
    """
    ## App context
    - **Version**: #{app.version}
    - **OS**: #{app.os}
    - **Locale**: #{app.locale}
    - **Theme**: #{app.theme}\
    """
  end

  defp info_hash_backticked(nil), do: nil
  defp info_hash_backticked(""), do: nil
  defp info_hash_backticked(hex) when is_binary(hex), do: "`#{hex}`"

  defp size_bytes_label(nil), do: nil
  defp size_bytes_label(n) when is_integer(n) and n >= 0, do: "#{n} bytes"

  defp magnet_line(nil), do: nil
  defp magnet_line(""), do: nil
  defp magnet_line(uri) when is_binary(uri), do: "`#{uri}`"

  defp percent_label(nil), do: nil

  defp percent_label(pct) when is_number(pct) do
    :erlang.float_to_binary(pct / 1, decimals: 1) <> "%"
  end

  defp peers_label(nil), do: nil
  defp peers_label(n) when is_integer(n) and n >= 0, do: Integer.to_string(n)

  defp rate_label(nil, nil), do: nil

  defp rate_label(down, up) do
    "↓ #{rate_number(down)} / ↑ #{rate_number(up)}"
  end

  defp rate_number(nil), do: "?"
  defp rate_number(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 1)

  defp size_pair_label(nil, nil), do: nil

  defp size_pair_label(downloaded, size) do
    "#{size_or_qmark(downloaded)} / #{size_or_qmark(size)}"
  end

  defp size_or_qmark(nil), do: "?"
  defp size_or_qmark(n) when is_integer(n) and n >= 0, do: "#{n}"

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end
end
