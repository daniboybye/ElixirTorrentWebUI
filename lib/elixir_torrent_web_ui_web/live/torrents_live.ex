defmodule ElixirTorrentWebUIWeb.TorrentsLive do
  use ElixirTorrentWebUIWeb, :live_view

  alias ElixirTorrentWebUI.Engine

  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:torrents, Engine.list_torrents())
      |> allow_upload(:torrent,
        accept: ~w(.torrent),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true
      )

    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :torrents, Engine.list_torrents())}
  end

  @impl true
  def handle_event("add_torrent", _params, socket) do
    {completed, _in_progress} = uploaded_entries(socket, :torrent)

    if completed == [] do
      # With auto_upload enabled this event fires during upload progress too.
      {:noreply, socket}
    else
      invalid = Enum.reject(completed, &torrent_file?/1)

      socket =
        Enum.reduce(invalid, socket, fn entry, acc ->
          cancel_upload(acc, :torrent, entry.ref)
        end)

      if invalid != [] do
        {:noreply, put_flash(socket, :error, "Only .torrent files are allowed")}
      else
        {paths, socket} =
          consume_uploaded_entries(socket, :torrent, fn %{path: path}, entry ->
            dest = persist_upload(path, entry)
            {:ok, dest}
          end)

        case paths do
          [path | _] ->
            case Engine.add_torrent(path) do
              {:ok, _pid} ->
                {:noreply,
                 socket
                 |> put_flash(:info, "Torrent added")
                 |> assign(:torrents, Engine.list_torrents())}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Failed to add torrent: #{inspect(reason)}")}
            end

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to add torrent")}
        end
      end
    end
  end

  @spec torrent_file?(Phoenix.LiveView.UploadEntry.t()) :: boolean()
  defp torrent_file?(entry) do
    entry.client_name
    |> String.downcase()
    |> String.ends_with?(".torrent")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-wrap items-center justify-end gap-3 rounded-xl border border-base-300 bg-base-200 px-4 py-3">
        <div class="flex items-center gap-2">
          <.theme_toggle />

          <form phx-change="add_torrent" phx-submit="add_torrent">
            <.live_file_input upload={@uploads.torrent} class="sr-only" />
            <label
              for={@uploads.torrent.ref}
              class="inline-flex cursor-pointer items-center rounded-md border border-transparent bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110"
            >
              Add torrent
            </label>
          </form>
        </div>
      </div>

      <div class="space-y-3">
        <div
          :for={torrent <- @torrents}
          id={"torrent-#{Torrent.hex_encoded_hash(torrent.hash)}"}
          class="rounded-2xl border border-base-300 bg-base-200 px-4 py-4"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="text-lg font-medium text-base-content">{torrent.name}</p>
              <p class="text-sm text-base-content/70">{torrent.status}</p>
            </div>
            <span class={status_badge_class(torrent.status)}>{short_status(torrent.status)}</span>
          </div>

          <div class="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-base-content/80">
            <span class="tabular-nums text-success">↓ {format_kbps(torrent.down_kbps)}</span>
            <span class="tabular-nums text-secondary">↑ {format_kbps(torrent.up_kbps)}</span>
            <span class="tabular-nums">👥 {torrent.peers}</span>
            <span class="tabular-nums">{format_percent(torrent.progress)}</span>
          </div>

          <div class="mt-3 h-1.5 overflow-hidden rounded-full bg-base-300">
            <div
              class="h-full rounded-full bg-gradient-to-r from-primary to-accent"
              style={"width: #{min(max(torrent.progress, 0.0), 100.0)}%"}
            >
            </div>
          </div>
        </div>

        <div
          id="torrent-drop-zone"
          phx-drop-target={@uploads.torrent.ref}
          class="rounded-2xl border border-dashed border-base-300 bg-base-200 px-6 py-10 text-center text-base-content/60"
        >
          Drag and drop a `.torrent` file here, or <label
            for={@uploads.torrent.ref}
            class="cursor-pointer text-primary underline"
          >
            Click to Add
          </label>.
        </div>
      </div>

      <div
        :if={@torrents == []}
        class="rounded-xl border border-base-300 bg-base-200 px-4 py-8 text-center text-base-content/70"
      >
        No active torrents. Add a `.torrent` file to start downloading.
      </div>
    </Layouts.app>
    """
  end

  @spec persist_upload(Path.t(), Phoenix.LiveView.UploadEntry.t()) :: Path.t()
  defp persist_upload(tmp_path, entry) do
    dir = Path.join(System.tmp_dir!(), "elixir_torrent_web_ui/uploads")
    File.mkdir_p!(dir)

    filename = "#{entry.uuid}-#{entry.client_name}"
    dest = Path.join(dir, filename)
    File.cp!(tmp_path, dest)
    dest
  end

  @spec format_kbps(number()) :: String.t()
  defp format_kbps(n) when is_integer(n) and n >= 1024, do: "#{Float.round(n / 1024, 2)} MB/s"
  defp format_kbps(n) when is_integer(n), do: "#{n} KB/s"
  defp format_kbps(n) when is_float(n) and n >= 1024.0, do: "#{Float.round(n / 1024.0, 2)} MB/s"
  defp format_kbps(n) when is_float(n), do: "#{Float.round(n, 1)} KB/s"
  defp format_kbps(_), do: "0 KB/s"

  @spec format_percent(number()) :: String.t()
  defp format_percent(n) when is_float(n), do: "#{Float.round(n, 1)}%"
  defp format_percent(n) when is_integer(n), do: "#{n}%"
  defp format_percent(_), do: "0%"

  @spec status_badge_class(String.t()) :: String.t()
  defp status_badge_class("Seeding"), do: "badge badge-success"
  defp status_badge_class("Connecting"), do: "badge badge-warning"
  defp status_badge_class("Idle"), do: "badge badge-ghost"
  defp status_badge_class(_), do: "badge badge-primary"

  @spec short_status(String.t()) :: String.t()
  defp short_status("Downloading" <> _), do: "Downloading"
  defp short_status(status), do: status

  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  defp theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={JS.dispatch("phx:toggle-theme")}
      class="inline-flex cursor-pointer items-center gap-2 rounded-md border border-base-300 bg-base-300 px-4 py-2 text-sm font-semibold text-base-content hover:bg-base-100"
      title="Toggle theme"
      aria-label="Toggle theme"
    >
      <.icon name="hero-sun-mini" class="size-4 [[data-theme=dark]_&]:hidden" />
      <.icon name="hero-moon-mini" class="hidden size-4 [[data-theme=dark]_&]:inline" />
      <span>Theme</span>
    </button>
    """
  end
end
