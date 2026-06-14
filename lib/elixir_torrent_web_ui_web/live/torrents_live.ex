defmodule ElixirTorrentWebUIWeb.TorrentsLive do
  use ElixirTorrentWebUIWeb, :live_view

  alias ElixirTorrentWebUI.Engine

  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    %{theme: theme, expanded: expanded} = ElixirTorrentWebUI.UiState.get()

    socket =
      socket
      |> assign(:theme, theme)
      |> assign(:expanded, expanded)
      |> assign(:remove_dialog, nil)
      |> assign(:player, nil)
      |> assign(:torrents, Engine.list_torrents(expanded))
      |> allow_upload(:torrent,
        accept: ~w(.torrent),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    socket =
      if connected?(socket) do
        push_event(socket, "set-theme", %{theme: theme})
      else
        socket
      end

    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, :torrents, Engine.list_torrents(socket.assigns.expanded))}
  end

  @impl true
  def handle_event("open_remove_dialog", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.torrents, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      torrent ->
        {:noreply,
         assign(socket, :remove_dialog, %{id: torrent.id, name: torrent.name, hash: torrent.hash})}
    end
  end

  @impl true
  def handle_event("close_remove_dialog", _params, socket) do
    {:noreply, assign(socket, :remove_dialog, nil)}
  end

  @impl true
  def handle_event(
        "open_player",
        %{"torrent_id" => torrent_id, "file_index" => file_index},
        socket
      ) do
    with {index, ""} <- Integer.parse(file_index),
         {:ok, file} <- Engine.resolve_video(torrent_id, index) do
      {:noreply,
       assign(socket, :player, %{
         torrent_id: torrent_id,
         file_index: index,
         name: file.name,
         src: ~p"/media/#{torrent_id}/#{index}"
       })}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Cannot play this file")}
    end
  end

  @impl true
  def handle_event("close_player", _params, socket) do
    {:noreply, assign(socket, :player, nil)}
  end

  @impl true
  def handle_event("confirm_remove", %{"delete_data" => delete_data}, socket) do
    case socket.assigns.remove_dialog do
      %{hash: hash, name: name, id: id} ->
        delete? = delete_data == "true"

        case Engine.remove_torrent(hash, delete_data: delete?) do
          :ok ->
            expanded = MapSet.delete(socket.assigns.expanded, id)
            :ok = ElixirTorrentWebUI.UiState.put_expanded(expanded)

            {:noreply,
             socket
             |> assign(:remove_dialog, nil)
             |> assign(:expanded, expanded)
             |> put_flash(:info, removed_flash(name, delete?))
             |> assign(:torrents, Engine.list_torrents(expanded))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to remove torrent: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    :ok = ElixirTorrentWebUI.UiState.put_expanded(expanded)

    {:noreply,
     socket
     |> assign(:expanded, expanded)
     |> assign(:torrents, Engine.list_torrents(expanded))}
  end

  @impl true
  def handle_event("show_folder", %{"id" => id}, socket) do
    case Engine.show_folder(id) do
      :ok ->
        {:noreply, socket}

      {:error, :unsupported_platform} ->
        {:noreply, put_flash(socket, :error, "Show Folder is only available on macOS")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not open folder in Finder")}
    end
  end

  @impl true
  def handle_event("toggle_theme", _params, socket) do
    theme = if(socket.assigns.theme == "dark", do: "light", else: "dark")
    :ok = ElixirTorrentWebUI.UiState.put_theme(theme)

    {:noreply,
     socket
     |> assign(:theme, theme)
     |> push_event("set-theme", %{theme: theme})}
  end

  # The form's `phx-change` is required to wire `<.live_file_input>` into the
  # upload protocol — without it the JS hook never preflights. The actual work
  # (consume + add to engine) happens in the `progress` callback below.
  #
  # We still use `validate` to catch files that Phoenix has flagged as invalid
  # (e.g. dropped `.png` triggers `:not_accepted` because of `accept: ~w(.torrent)`).
  # We cancel them so they don't sit in the upload state forever, and surface a
  # flash so the user knows what happened.
  @impl true
  def handle_event("validate", _params, socket) do
    invalid = Enum.reject(socket.assigns.uploads.torrent.entries, & &1.valid?)

    socket =
      Enum.reduce(invalid, socket, fn entry, acc ->
        cancel_upload(acc, :torrent, entry.ref)
      end)

    socket =
      if invalid == [],
        do: socket,
        else: put_flash(socket, :error, "Only .torrent files are allowed")

    {:noreply, socket}
  end

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
           |> assign(:torrents, Engine.list_torrents(socket.assigns.expanded))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to add torrent: #{inspect(reason)}")}
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
      <div id="torrents-live" phx-hook="UiState" class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-base-300 bg-base-200 px-4 py-3">
          <div class="flex items-center gap-3">
            <.app_logo id="app-logo" class="size-9 shrink-0" />
            <div>
              <p class="text-base font-semibold text-base-content">ElixirTorrent Web</p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <.theme_toggle theme={@theme} />

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
          <.torrent_card
            :for={torrent <- @torrents}
            torrent={torrent}
            expanded={MapSet.member?(@expanded, torrent.id)}
          />

          <div class="rounded-2xl border border-dashed border-base-300 bg-base-200 px-6 py-10 text-center text-base-content/60">
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
      </div>

      <.remove_torrent_dialog dialog={@remove_dialog} />
      <.media_player_modal player={@player} />
    </Layouts.app>

    <div
      id="drag-overlay"
      phx-hook=".DragOverlay"
      phx-update="ignore"
      class="pointer-events-none fixed inset-0 z-40 hidden items-center justify-center bg-base-100/80 backdrop-blur-sm transition-opacity"
      aria-hidden="true"
    >
      <div
        data-overlay-card
        class="rounded-3xl border-4 border-dashed border-primary bg-base-200/90 px-12 py-10 text-center shadow-2xl"
      >
        <span data-overlay-icon-ok class="block">
          <.app_logo class="mx-auto size-16" />
        </span>
        <span data-overlay-icon-no class="hidden">
          <.icon name="hero-no-symbol" class="mx-auto size-16 text-error" />
        </span>
        <p data-overlay-title class="mt-4 text-4xl font-bold text-base-content">
          Drop files here!
        </p>
        <p data-overlay-hint class="mt-2 text-sm text-base-content/70">
          Only <code>.torrent</code> files accepted
        </p>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".DragOverlay">
      export default {
        mounted() {
          this.overlay = this.el
          this.dragCounter = 0

          this.handlers = {
            dragenter: (e) => {
              if (!this.hasFiles(e)) return
              e.preventDefault()
              this.dragCounter++
              if (this.dragCounter === 1) this.show(this.acceptsDrag(e))
            },
            dragleave: (e) => {
              if (!this.hasFiles(e)) return
              this.dragCounter--
              if (this.dragCounter <= 0) {
                this.dragCounter = 0
                this.hide()
              }
            },
            dragover: (e) => {
              if (!this.hasFiles(e)) return
              e.preventDefault()
              const accepted = this.acceptsDrag(e)
              e.dataTransfer.dropEffect = accepted ? "copy" : "none"
              this.setOverlayState(accepted)
            },
            drop: (e) => {
              this.dragCounter = 0
              this.hide()
              if (!this.hasFiles(e) || !e.dataTransfer.files.length) return
              e.preventDefault()
              e.stopPropagation()

              // Forward files to the live upload input directly. We can't trust
              // a static `phx-drop-target` ref because the input's id is
              // re-issued by Phoenix on upload state changes; the data-attr
              // selector always matches the current input.
              const input = document.querySelector('input[type="file"][data-phx-upload-ref]')
              if (!input || input.disabled) return

              const dt = new DataTransfer()
              for (const f of e.dataTransfer.files) dt.items.add(f)
              input.files = dt.files
              input.dispatchEvent(new Event("input", { bubbles: true }))
              input.dispatchEvent(new Event("change", { bubbles: true }))
            }
          }

          for (const [event, handler] of Object.entries(this.handlers)) {
            window.addEventListener(event, handler)
          }
        },

        destroyed() {
          if (!this.handlers) return
          for (const [event, handler] of Object.entries(this.handlers)) {
            window.removeEventListener(event, handler)
          }
        },

        show(accepted) {
          this.overlay.classList.remove("hidden", "pointer-events-none")
          this.overlay.classList.add("flex", "pointer-events-auto")
          this.setOverlayState(accepted)
        },

        hide() {
          this.overlay.classList.add("hidden", "pointer-events-none")
          this.overlay.classList.remove("flex", "pointer-events-auto")
          this.setOverlayState(true)
        },

        setOverlayState(accepted) {
          const card = this.overlay.querySelector("[data-overlay-card]")
          const title = this.overlay.querySelector("[data-overlay-title]")
          const hint = this.overlay.querySelector("[data-overlay-hint]")
          const okIcon = this.overlay.querySelector("[data-overlay-icon-ok]")
          const noIcon = this.overlay.querySelector("[data-overlay-icon-no]")
          if (!card) return
          if (accepted) {
            card.classList.remove("border-error")
            card.classList.add("border-primary")
            if (title) title.textContent = "Drop files here!"
            if (hint) hint.classList.remove("text-error")
            if (okIcon) { okIcon.classList.remove("hidden"); okIcon.classList.add("block") }
            if (noIcon) { noIcon.classList.add("hidden"); noIcon.classList.remove("block") }
          } else {
            card.classList.add("border-error")
            card.classList.remove("border-primary")
            if (title) title.textContent = "This file type is not supported"
            if (hint) hint.classList.add("text-error")
            if (okIcon) { okIcon.classList.add("hidden"); okIcon.classList.remove("block") }
            if (noIcon) { noIcon.classList.remove("hidden"); noIcon.classList.add("block") }
          }
        },

        hasFiles(e) {
          return e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files")
        },

        // We can only inspect MIME `kind`/`type` during drag (file *names* are
        // hidden by the browser for security). Finder sometimes reports an
        // empty MIME for `.torrent` because the type isn't registered in macOS,
        // so we treat empty as "maybe accepted" — final extension validation
        // happens server-side in the `progress` callback after drop.
        acceptsDrag(e) {
          const items = e.dataTransfer && e.dataTransfer.items
          if (!items || items.length === 0) return true
          return Array.from(items).every(item => {
            if (item.kind !== "file") return false
            const type = (item.type || "").toLowerCase()
            return type === "" || type === "application/x-bittorrent"
          })
        }
      }
    </script>
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
  attr :expanded, :boolean, required: true

  defp torrent_card(assigns) do
    ~H"""
    <div
      id={"torrent-#{@torrent.id}"}
      class="relative overflow-visible rounded-2xl border border-base-300 bg-base-200"
    >
      <div class="flex items-start gap-3 px-4 py-4">
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
        <div class="mt-1 flex shrink-0 items-center gap-1">
          <div class="tooltip tooltip-top" data-tip="Show Folder">
            <button
              type="button"
              id={"torrent-folder-#{@torrent.id}"}
              phx-click="show_folder"
              phx-value-id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
              aria-label="Show Folder"
            >
              <.icon name="hero-folder-open" class="size-5" />
            </button>
          </div>
          <div class="tooltip tooltip-top" data-tip="Remove Torrent">
            <button
              type="button"
              id={"torrent-remove-#{@torrent.id}"}
              phx-click="open_remove_dialog"
              phx-value-id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-error"
              aria-label="Remove Torrent"
            >
              <.icon name="hero-trash" class="size-5" />
            </button>
          </div>
          <div
            class="tooltip tooltip-top"
            data-tip={if(@expanded, do: "Hide Torrents Files", else: "Show Torrents Files")}
          >
            <button
              type="button"
              id={"torrent-expand-#{@torrent.id}"}
              phx-click="toggle_expand"
              phx-value-id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
              aria-expanded={to_string(@expanded)}
              aria-controls={"torrent-files-#{@torrent.id}"}
              aria-label={if(@expanded, do: "Hide Torrents Files", else: "Show Torrents Files")}
            >
              <.icon
                name={if(@expanded, do: "hero-chevron-up", else: "hero-chevron-down")}
                class="size-5"
              />
            </button>
          </div>
        </div>
      </div>

      <%= if @torrent.status == "Seeding" do %>
        <div class={[
          "flex flex-wrap items-center gap-x-5 gap-y-2 px-4 pb-4 text-sm tabular-nums text-base-content/80",
          !@expanded && "rounded-b-2xl"
        ]}>
          <span class="min-w-[3rem] text-secondary">↑ {format_speed(@torrent.up_kbps)}</span>
          <span class="text-base-content/40">|</span>
          <span class="min-w-[1.6rem]">👥 {@torrent.peers}</span>
        </div>
      <% else %>
        <div class="flex flex-wrap items-center gap-x-5 gap-y-2 px-4 pb-3 text-sm tabular-nums text-base-content/80">
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

        <div class="mx-4 mb-4 h-1.5 overflow-hidden rounded-full bg-base-300">
          <div
            class="h-full rounded-full bg-gradient-to-r from-primary to-accent transition-[width] duration-500"
            style={"width: #{clamp_percent(@torrent.progress)}%"}
          >
          </div>
        </div>
      <% end %>

      <%= if @expanded do %>
        <div
          id={"torrent-files-#{@torrent.id}"}
          class="rounded-b-2xl border-t border-base-300 bg-base-100/40 px-4 py-4"
        >
          <div class="flex flex-col gap-4 md:grid md:grid-cols-[max-content_minmax(0,1fr)] md:items-start md:gap-x-4">
            <div class="flex flex-row gap-8 text-sm text-base-content/80 md:flex-col md:gap-3 md:shrink-0">
              <div class="shrink-0">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Date Added
                </p>
                <p class="mt-1 tabular-nums">{format_date(@torrent.added_at)}</p>
              </div>
              <div class="shrink-0">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Total Files
                </p>
                <p class="mt-1 tabular-nums">{@torrent.file_count}</p>
              </div>
              <div class="shrink-0">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  Total Size
                </p>
                <p class="mt-1 tabular-nums">{format_bytes(@torrent.bytes_size)}</p>
              </div>
            </div>

            <div class="min-w-0 w-full">
              <div class="w-full overflow-hidden rounded-xl border border-base-300">
                <div class="grid grid-cols-[minmax(0,1fr)_5rem_6rem] gap-3 border-b border-base-300 bg-base-300/50 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <span>Name</span>
                  <span class="text-right">Size</span>
                  <span class="text-right">Download</span>
                </div>
                <div
                  :for={file <- @torrent.files}
                  id={"torrent-file-#{@torrent.id}-#{file.index}"}
                  class={[
                    "grid grid-cols-[minmax(0,1fr)_5rem_6rem] gap-3 border-b border-base-300/70 px-4 py-3 text-sm last:border-b-0 transition-colors hover:bg-base-300/70",
                    Engine.playable_file?(file) && "group cursor-pointer"
                  ]}
                  phx-click={Engine.playable_file?(file) && "open_player"}
                  phx-value-torrent_id={@torrent.id}
                  phx-value-file_index={file.index}
                  aria-label={Engine.playable_file?(file) && "Play #{file.name}"}
                >
                  <div class="flex min-w-0 items-center gap-3">
                    <%= if Engine.playable_file?(file) do %>
                      <span
                        id={"torrent-file-play-#{@torrent.id}-#{file.index}"}
                        class="inline-flex size-9 shrink-0 items-center justify-center rounded-full border-2 border-base-content bg-transparent text-base-content transition group-hover:border-success group-hover:bg-success group-hover:text-white"
                        aria-hidden="true"
                      >
                        <.icon name="hero-play" class="size-4 translate-x-px" />
                      </span>
                    <% end %>
                    <div class="min-w-0 flex-1">
                      <p class="truncate font-medium text-base-content" title={file.path}>
                        {file.name}
                      </p>
                      <p :if={file.path != file.name} class="truncate text-xs text-base-content/50">
                        {file.path}
                      </p>
                    </div>
                  </div>
                  <span class="self-center text-right tabular-nums text-base-content/80">
                    {format_bytes(file.length)}
                  </span>
                  <div class="self-center text-right">
                    <%= if file.complete? do %>
                      <span class="inline-flex items-center justify-end gap-1 text-success">
                        <.icon name="hero-check-circle" class="size-4" />
                        <span class="sr-only">Downloaded</span>
                      </span>
                    <% else %>
                      <span class="tabular-nums text-info">{format_percent(file.progress)}</span>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :player, :map, default: nil

  defp media_player_modal(assigns) do
    ~H"""
    <div
      :if={@player}
      id="media-player-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="media-player-title"
    >
      <button
        type="button"
        id="media-player-backdrop"
        phx-click="close_player"
        class="absolute inset-0 cursor-default bg-black/80"
        aria-label="Close player"
      />
      <div class="relative z-10 w-full max-w-5xl rounded-2xl border border-base-300 bg-base-100 p-4 shadow-2xl sm:p-6">
        <div class="mb-4 flex items-start justify-between gap-4">
          <h2
            id="media-player-title"
            class="min-w-0 truncate text-base font-semibold text-base-content sm:text-lg"
            title={@player.name}
          >
            {@player.name}
          </h2>
          <button
            type="button"
            id="media-player-close"
            phx-click="close_player"
            class="inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <div phx-update="ignore" id="media-player-video">
          <video
            id="media-player-element"
            controls
            autoplay
            playsinline
            class="aspect-video w-full rounded-xl bg-black"
            src={@player.src}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :dialog, :map, default: nil

  defp remove_torrent_dialog(assigns) do
    ~H"""
    <div
      :if={@dialog}
      id="remove-torrent-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="remove-torrent-dialog-title"
    >
      <button
        type="button"
        id="remove-torrent-dialog-backdrop"
        phx-click="close_remove_dialog"
        class="absolute inset-0 cursor-default bg-black/50"
        aria-label="Close dialog"
      />
      <div class="relative z-10 w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl">
        <div class="flex items-start justify-between gap-4">
          <h2 id="remove-torrent-dialog-title" class="text-xl font-semibold text-[#d15555]">
            Remove Torrent?
          </h2>
          <button
            type="button"
            id="remove-torrent-dialog-close"
            phx-click="close_remove_dialog"
            class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <p class="mt-4 text-sm text-base-content/80">
          Are you sure you want to remove the selected torrent?
        </p>
        <p class="mt-3 break-words text-sm font-medium text-base-content">{@dialog.name}</p>

        <div class="mt-6 flex flex-wrap justify-end gap-3">
          <button
            type="button"
            id="remove-torrent-confirm"
            phx-click="confirm_remove"
            phx-value-delete_data="false"
            class="inline-flex cursor-pointer items-center rounded-lg bg-[#d15555] px-5 py-2.5 text-sm font-semibold text-white transition hover:brightness-110"
          >
            Remove Torrent
          </button>
          <button
            type="button"
            id="remove-torrent-confirm-data"
            phx-click="confirm_remove"
            phx-value-delete_data="true"
            class="inline-flex cursor-pointer items-center rounded-lg bg-[#d15555] px-5 py-2.5 text-sm font-semibold text-white transition hover:brightness-110"
          >
            Remove Torrent + Data
          </button>
        </div>
      </div>
    </div>
    """
  end

  @spec removed_flash(String.t(), boolean()) :: String.t()
  defp removed_flash(name, true), do: "Removed torrent and data: #{name}"
  defp removed_flash(name, false), do: "Removed torrent: #{name}"

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

  @spec format_date(DateTime.t() | nil) :: String.t()
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%-m/%-d/%Y")
  defp format_date(_), do: "—"

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

  attr :theme, :string, required: true

  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  defp theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_theme"
      class="inline-flex cursor-pointer items-center gap-2 rounded-md border border-base-300 bg-base-300 px-4 py-2 text-sm font-semibold text-base-content hover:bg-base-100"
      title="Toggle theme"
      aria-label="Toggle theme"
    >
      <.icon name="hero-sun-mini" class={["size-4", @theme == "light" && "hidden"]} />
      <.icon name="hero-moon-mini" class={["size-4", @theme == "dark" && "hidden"]} />
      <span>Theme</span>
    </button>
    """
  end
end
