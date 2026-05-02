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
        auto_upload: true,
        progress: &handle_progress/3
      )

    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :torrents, Engine.list_torrents())}
  end

  # The form's `phx-change` is required to wire `<.live_file_input>` into the
  # upload protocol — without it the JS hook never preflights. The actual work
  # (consume + add to engine) happens in the `progress` callback below.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # The `progress` callback (idiomatic for `auto_upload: true`) fires once per
  # upload progress update. We bail until `entry.done?` and then consume the
  # single entry. Using `consume_uploaded_entry/3` (singular) avoids the race
  # that crashes `consume_uploaded_entries/3` (plural) when chunks arrive
  # interleaved with the change event.
  @spec handle_progress(:torrent, Phoenix.LiveView.UploadEntry.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp handle_progress(:torrent, %{done?: false}, socket), do: {:noreply, socket}

  defp handle_progress(:torrent, entry, socket) do
    if torrent_file?(entry) do
      path =
        consume_uploaded_entry(socket, entry, fn %{path: tmp_path} ->
          {:ok, persist_upload(tmp_path, entry)}
        end)

      case Engine.add_torrent(path) do
        {:ok, _pid} ->
          {:noreply,
           socket
           |> put_flash(:info, "Torrent added: #{entry.client_name}")
           |> assign(:torrents, Engine.list_torrents())}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Failed to add torrent: #{inspect(reason)}")}
      end
    else
      {:noreply,
       socket
       |> cancel_upload(:torrent, entry.ref)
       |> put_flash(:error, "Only .torrent files are allowed")}
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

          <form id="add-torrent-form" phx-change="validate" phx-submit="validate">
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
        <.torrent_card :for={torrent <- @torrents} torrent={torrent} />

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

  attr :torrent, Engine.TorrentRow, required: true

  defp torrent_card(assigns) do
    ~H"""
    <div
      id={"torrent-#{Torrent.hex_encoded_hash(@torrent.hash)}"}
      class="rounded-2xl border border-base-300 bg-base-200 px-4 py-4"
    >
      <div class="flex items-start gap-3">
        <span
          class={[
            "mt-2 inline-block size-2.5 shrink-0 rounded-full",
            status_dot_class(@torrent.status)
          ]}
          aria-hidden="true"
        />
        <div class="min-w-0 flex-1">
          <p class="truncate text-base font-medium text-base-content" title={@torrent.name}>
            {@torrent.name}
          </p>
          <p class={["text-sm font-medium", status_text_class(@torrent.status)]}>
            {@torrent.status}
          </p>
        </div>
      </div>

      <%= if @torrent.status == "Seeding" do %>
        <div class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm tabular-nums text-base-content/80">
          <span class="min-w-[3rem] text-secondary">↑ {format_speed(@torrent.up_kbps)}</span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[1.6rem]">👥 {@torrent.peers}</span>
        </div>
      <% else %>
        <div class="mt-3 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm tabular-nums text-base-content/80">
          <span class="min-w-[3rem] text-success">↓ {format_speed(@torrent.down_kbps)}</span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[3rem] text-secondary">↑ {format_speed(@torrent.up_kbps)}</span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[1.6rem]">👥 {@torrent.peers}</span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[4.8rem]">
            {format_bytes(@torrent.bytes_downloaded)} / {format_bytes(@torrent.bytes_size)}
          </span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[2.2rem]">⏱ {format_eta(@torrent.eta_seconds)}</span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[1.4rem]">{format_percent(@torrent.progress)}</span>
        </div>

        <div class="mt-3 h-1.5 overflow-hidden rounded-full bg-base-300">
          <div
            class="h-full rounded-full bg-gradient-to-r from-primary to-accent transition-[width] duration-500"
            style={"width: #{clamp_percent(@torrent.progress)}%"}
          >
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @spec format_speed(number()) :: String.t()
  defp format_speed(kbps) when is_number(kbps) and kbps > 0,
    do: format_bytes(round(kbps * 1024)) <> "/s"

  defp format_speed(_), do: "0 B/s"

  @spec format_bytes(number()) :: String.t()
  defp format_bytes(n) when is_number(n) and n >= 1024 * 1024 * 1024 * 1024,
    do: format_unit(n / (1024 * 1024 * 1024 * 1024), "TB")

  defp format_bytes(n) when is_number(n) and n >= 1024 * 1024 * 1024,
    do: format_unit(n / (1024 * 1024 * 1024), "GB")

  defp format_bytes(n) when is_number(n) and n >= 1024 * 1024,
    do: format_unit(n / (1024 * 1024), "MB")

  defp format_bytes(n) when is_number(n) and n >= 1024,
    do: format_unit(n / 1024, "KB")

  defp format_bytes(n) when is_integer(n) and n >= 0, do: "#{n} B"
  defp format_bytes(_), do: "0 B"

  defp format_unit(value, unit) do
    rounded = Float.round(value, 2)

    if rounded == Float.floor(rounded) do
      "#{trunc(rounded)} #{unit}"
    else
      "#{rounded} #{unit}"
    end
  end

  @spec format_eta(nil | :infinity | number()) :: String.t()
  defp format_eta(nil), do: "—"
  defp format_eta(:infinity), do: "∞"

  defp format_eta(seconds) when is_number(seconds) do
    seconds = round(seconds)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
      true -> "#{div(seconds, 86_400)}d #{rem(div(seconds, 3600), 24)}h"
    end
  end

  @spec format_percent(number()) :: String.t()
  defp format_percent(n) when is_float(n), do: "#{Float.round(n, 1)}%"
  defp format_percent(n) when is_integer(n), do: "#{n}%"
  defp format_percent(_), do: "0%"

  @spec clamp_percent(number()) :: float()
  defp clamp_percent(n) when is_number(n), do: min(max(n * 1.0, 0.0), 100.0)
  defp clamp_percent(_), do: 0.0

  @spec status_text_class(String.t()) :: String.t()
  defp status_text_class("Seeding"), do: "text-success"
  defp status_text_class("Connecting"), do: "text-warning"
  defp status_text_class("Idle"), do: "text-base-content/60"
  defp status_text_class(_), do: "text-info"

  @spec status_dot_class(String.t()) :: String.t()
  defp status_dot_class("Seeding"), do: "bg-success"
  defp status_dot_class("Connecting"), do: "bg-warning animate-pulse"
  defp status_dot_class("Idle"), do: "bg-base-content/40"
  defp status_dot_class(_), do: "bg-info"

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
