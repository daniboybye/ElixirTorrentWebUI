defmodule ElixirTorrentWebUIWeb.TorrentsLive do
  use ElixirTorrentWebUIWeb, :live_view

  alias ElixirTorrentWebUI.{
    DefaultHandler,
    Engine,
    IssueReport,
    Locale,
    MagnetIngest,
    StatsStore,
    TorrentIngest,
    TorrentSummary
  }

  require Logger

  @refresh_ms 1_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    %{theme: theme, expanded: expanded, download_folder: download_folder} =
      ElixirTorrentWebUI.UiState.get()

    locale = socket.assigns.locale

    socket =
      socket
      |> assign(:theme, theme)
      |> assign(:expanded, expanded)
      |> assign(:remove_dialog, nil)
      |> assign(:settings_open, false)
      |> assign(:settings_locale, locale)
      |> assign(:settings_download_folder, download_folder)
      |> assign(:download_folder, download_folder)
      |> assign(:default_handler, DefaultHandler.status())
      |> assign(:default_prompt_dismissed, false)
      |> assign(:report_open, false)
      |> assign(:report_form, empty_report_form())
      |> assign(:player, nil)
      |> assign_torrents(Engine.list_torrents(expanded))
      |> allow_upload(:torrent,
        accept: ~w(.torrent),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> allow_upload(:report_torrent,
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

    socket =
      if connected?(socket) do
        push_event(socket, "set-locale", %{locale: locale})
      else
        socket
      end

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(ElixirTorrentWebUI.PubSub, MagnetIngest.topic())
        Phoenix.PubSub.subscribe(ElixirTorrentWebUI.PubSub, TorrentIngest.topic())
        Process.send_after(self(), :refresh, @refresh_ms)
        apply_recent_magnet_result(socket, expanded)
      else
        socket
      end

    {:ok, socket}
  end

  @spec apply_recent_magnet_result(Phoenix.LiveView.Socket.t(), MapSet.t()) ::
          Phoenix.LiveView.Socket.t()
  defp apply_recent_magnet_result(socket, expanded) do
    case MagnetIngest.take_last_result() do
      {_uri, {:ok, :fetching}} ->
        put_flash(socket, :info, gettext("Magnet metadata fetch already in progress"))

      {_uri, {:ok, _pid}} ->
        socket
        |> put_flash(:info, gettext("Magnet download started"))
        |> assign_torrents(Engine.list_torrents(expanded))

      {_uri, {:error, reason}} ->
        put_flash(socket, :error, Engine.magnet_error_message(reason))

      nil ->
        socket
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:magnet_ingest, _uri, {:ok, :fetching}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Magnet metadata fetch already in progress"))
     |> assign_torrents(Engine.list_torrents(socket.assigns.expanded))}
  end

  def handle_info({:magnet_ingest, _uri, {:ok, _pid}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Magnet download started"))
     |> assign_torrents(Engine.list_torrents(socket.assigns.expanded))}
  end

  def handle_info({:magnet_ingest, _uri, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, Engine.magnet_error_message(reason))}
  end

  def handle_info({:torrent_ingest, path, {:ok, _pid}}, socket) do
    name = Path.basename(path)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Torrent added: %{name}", name: name))
     |> assign_torrents(Engine.list_torrents(socket.assigns.expanded))}
  end

  def handle_info({:torrent_ingest, _path, {:error, reason}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Failed to add torrent: %{reason}", reason: inspect(reason))
     )}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign_torrents(socket, Engine.list_torrents(socket.assigns.expanded))}
  end

  @impl Phoenix.LiveView
  def handle_event("open_remove_dialog", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.torrents, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      torrent ->
        {:noreply,
         assign(socket, :remove_dialog, %{id: torrent.id, name: torrent.name, hash: torrent.hash})}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("close_remove_dialog", _params, socket) do
    {:noreply, assign(socket, :remove_dialog, nil)}
  end

  @impl Phoenix.LiveView
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
        {:noreply, put_flash(socket, :error, gettext("Cannot play this file"))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(
        "open_image",
        %{"torrent_id" => torrent_id, "file_index" => file_index},
        socket
      ) do
    with {index, ""} <- Integer.parse(file_index),
         :ok <- Engine.open_image(torrent_id, index) do
      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not open this image"))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("close_player", _params, socket) do
    {:noreply, assign(socket, :player, nil)}
  end

  @impl Phoenix.LiveView
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
             |> assign_torrents(Engine.list_torrents(expanded))}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to remove torrent: %{reason}", reason: inspect(reason))
             )}
        end

      nil ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
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
     |> assign_torrents(Engine.list_torrents(expanded))}
  end

  @impl Phoenix.LiveView
  def handle_event("show_folder", %{"id" => id}, socket) do
    case Engine.show_folder(id) do
      :ok ->
        {:noreply, socket}

      {:error, :unsupported_platform} ->
        {:noreply, put_flash(socket, :error, gettext("Show Folder is only available on macOS"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not open folder in Finder"))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_theme", _params, socket) do
    theme = if(socket.assigns.theme == "dark", do: "light", else: "dark")
    :ok = ElixirTorrentWebUI.UiState.put_theme(theme)

    {:noreply,
     socket
     |> assign(:theme, theme)
     |> push_event("set-theme", %{theme: theme})}
  end

  @impl Phoenix.LiveView
  def handle_event("open_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_open, true)
     |> assign(:settings_locale, socket.assigns.locale)
     |> assign(:settings_download_folder, socket.assigns.download_folder)
     |> assign(:default_handler, DefaultHandler.status())}
  end

  @impl Phoenix.LiveView
  def handle_event("close_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_open, false)
     |> assign(:settings_locale, socket.assigns.locale)
     |> assign(:settings_download_folder, socket.assigns.download_folder)}
  end

  @impl Phoenix.LiveView
  def handle_event("choose_download_folder", _params, socket) do
    case Engine.choose_download_folder() do
      {:ok, folder} ->
        {:noreply, assign(socket, :settings_download_folder, folder)}

      {:error, :unsupported_platform} ->
        {:noreply, put_flash(socket, :error, gettext("Choose Folder is only available on macOS"))}

      {:error, :cancelled} ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not choose download folder"))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("settings_locale_changed", %{"locale" => locale}, socket) do
    {:noreply, assign(socket, :settings_locale, Locale.normalize(locale))}
  end

  @impl Phoenix.LiveView
  def handle_event("apply_settings", %{"locale" => locale}, socket) do
    locale = Locale.normalize(locale)
    download_folder = socket.assigns.settings_download_folder

    :ok = ElixirTorrentWebUI.UiState.put_locale(locale)
    :ok = ElixirTorrentWebUI.UiState.put_download_folder(download_folder)

    {:noreply,
     socket
     |> assign(:download_folder, download_folder)
     |> push_navigate(to: ~p"/locale/#{locale}")}
  end

  @impl Phoenix.LiveView
  def handle_event("reset_statistics", _params, socket) do
    :ok = StatsStore.reset()

    {:noreply,
     socket
     |> put_flash(:info, gettext("Transfer statistics reset"))
     |> assign_torrents(Engine.list_torrents(socket.assigns.expanded))}
  end

  @impl Phoenix.LiveView
  def handle_event("request_default_handler", _params, socket) do
    case DefaultHandler.request_default() do
      :ok ->
        status = DefaultHandler.status()

        socket =
          socket
          |> put_flash(
            :info,
            gettext(
              "Confirm ElixirTorrent Web in the system dialog to finish setting the default."
            )
          )
          |> assign(:default_handler, status)

        # `request_default/0` already gave the OS a moment to catch up, so
        # this usually already reflects the change. When it does not, wait
        # for the launcher to notify us rather than asking again on a timer
        # — see `await_default_handler/1` for why this has to be async.
        socket =
          if DefaultHandler.both_default?(status) do
            socket
          else
            await_default_handler(socket)
          end

        {:noreply, socket}

      {:error, :launcher_unavailable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Setting the default program is only available in the packaged app.")
         )}

      {:error, :unsupported_platform} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Setting the default program is only available on macOS and Windows.")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not set as default program"))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("dismiss_default_prompt", _params, socket) do
    {:noreply, assign(socket, :default_prompt_dismissed, true)}
  end

  @impl Phoenix.LiveView
  def handle_event("open_report", params, socket) do
    torrent_context =
      case Map.get(params, "torrent_id") do
        id when is_binary(id) and id != "" ->
          socket.assigns.torrents
          |> Enum.find(&(&1.id == id))
          |> torrent_row_to_context()

        _ ->
          nil
      end

    form =
      empty_report_form()
      |> Map.put(:torrent_context, torrent_context)

    {:noreply,
     socket
     |> assign(:report_open, true)
     |> assign(:report_form, form)}
  end

  @impl Phoenix.LiveView
  def handle_event("close_report", _params, socket) do
    {:noreply,
     socket
     |> assign(:report_open, false)
     |> reset_report_upload()}
  end

  @impl Phoenix.LiveView
  def handle_event("update_report", params, socket) do
    category =
      params
      |> Map.get("category", "")
      |> nilify_blank()

    magnet =
      params
      |> Map.get("magnet", "")
      |> nilify_blank()

    updated =
      socket.assigns.report_form
      |> Map.put(:category, category)
      |> Map.put(:description, Map.get(params, "description", ""))
      |> Map.put(:magnet, magnet)

    {:noreply, assign(socket, :report_form, updated)}
  end

  @impl Phoenix.LiveView
  def handle_event("clear_report_torrent", _params, socket) do
    {:noreply,
     socket
     |> assign(:report_form, Map.put(socket.assigns.report_form, :torrent_summary, nil))
     |> reset_report_upload()}
  end

  @impl Phoenix.LiveView
  def handle_event("add_magnet", params, socket) do
    case Map.get(params, "error") do
      "clipboard" ->
        {:noreply, put_flash(socket, :error, gettext("Could not read clipboard"))}

      _ ->
        magnet =
          params
          |> Map.get("magnet", "")
          |> String.trim()

        cond do
          magnet == "" ->
            {:noreply, put_flash(socket, :error, gettext("Paste a magnet link"))}

          not Engine.valid_magnet?(magnet) ->
            {:noreply, put_flash(socket, :error, gettext("Not a valid magnet link"))}

          true ->
            :ok = MagnetIngest.submit(magnet)
            {:noreply, put_flash(socket, :info, gettext("Fetching metadata from peers…"))}
        end
    end
  end

  # The form's `phx-change` is required to wire `<.live_file_input>` into the
  # upload protocol — without it the JS hook never preflights. The actual work
  # (consume + add to engine) happens in the `progress` callback below.
  #
  # We still use `validate` to catch files that Phoenix has flagged as invalid
  # (e.g. dropped `.png` triggers `:not_accepted` because of `accept: ~w(.torrent)`).
  # We cancel them so they don't sit in the upload state forever, and surface a
  # flash so the user knows what happened.
  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, prune_invalid_upload(socket, :torrent)}
  end

  @impl Phoenix.LiveView
  def handle_event("validate_report_torrent", _params, socket) do
    {:noreply, prune_invalid_upload(socket, :report_torrent)}
  end

  @spec prune_invalid_upload(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  defp prune_invalid_upload(socket, key) do
    invalid = Enum.reject(socket.assigns.uploads[key].entries, & &1.valid?)

    socket =
      Enum.reduce(invalid, socket, fn entry, acc ->
        cancel_upload(acc, key, entry.ref)
      end)

    if invalid == [],
      do: socket,
      else: put_flash(socket, :error, gettext("Only .torrent files are allowed"))
  end

  # The `progress` callback (idiomatic for `auto_upload: true`) fires once per
  # upload progress update. We bail until `entry.done?` and then consume the
  # single entry. Using `consume_uploaded_entry/3` (singular) avoids the race
  # that crashes `consume_uploaded_entries/3` (plural) when chunks arrive
  # interleaved with the change event.
  @spec handle_progress(
          :torrent | :report_torrent,
          Phoenix.LiveView.UploadEntry.t(),
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp handle_progress(_kind, %{done?: false}, socket), do: {:noreply, socket}

  defp handle_progress(:report_torrent, entry, socket) do
    if torrent_file?(entry) do
      # `consume_uploaded_entry/3` unwraps the `{:ok, value}` its callback must
      # return, so the parse result has to be wrapped once more — returning
      # `TorrentSummary.from_path/1` directly hands back a bare summary map and
      # the `case` below never matches, crashing the LiveView.
      summary =
        consume_uploaded_entry(socket, entry, fn %{path: tmp_path} ->
          {:ok, TorrentSummary.from_path(tmp_path)}
        end)

      case summary do
        {:ok, summary} ->
          form = Map.put(socket.assigns.report_form, :torrent_summary, summary)
          {:noreply, assign(socket, :report_form, form)}

        {:error, reason} ->
          Logger.warning("TorrentsLive: report attachment rejected reason=#{inspect(reason)}")
          {:noreply, put_flash(socket, :error, gettext("Could not read that .torrent file"))}
      end
    else
      {:noreply,
       socket
       |> cancel_upload(:report_torrent, entry.ref)
       |> put_flash(:error, gettext("Only .torrent files are allowed"))}
    end
  end

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
           |> put_flash(:info, gettext("Torrent added: %{name}", name: entry.client_name))
           |> assign_torrents(Engine.list_torrents(socket.assigns.expanded))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to add torrent: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:noreply,
       socket
       |> cancel_upload(:torrent, entry.ref)
       |> put_flash(:error, gettext("Only .torrent files are allowed"))}
    end
  end

  @spec torrent_file?(Phoenix.LiveView.UploadEntry.t()) :: boolean()
  defp torrent_file?(entry) do
    entry.client_name
    |> String.downcase()
    |> String.ends_with?(".torrent")
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    _ = Locale.put(assigns.locale)

    ~H"""
    <Layouts.app flash={@flash}>
      <div id="torrents-live" phx-hook="UiState" data-locale={@locale} class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-base-300 bg-base-200 px-4 py-3">
          <div class="flex items-center gap-3">
            <.app_logo id="app-logo" class="size-9 shrink-0" />
            <div>
              <p class="text-base font-semibold text-base-content">ElixirTorrent Web</p>
            </div>
          </div>

          <.aggregate_stats_bar stats={@stats} />

          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              id="paste-magnet-go"
              phx-hook=".PasteMagnet"
              class="inline-flex h-9 cursor-pointer items-center rounded-md border border-transparent bg-primary px-4 text-sm font-semibold text-primary-content hover:brightness-110"
              aria-label={gettext("Paste magnet & Go")}
            >
              {gettext("Paste magnet & Go")}
            </button>

            <form id="add-torrent-form" phx-change="validate" phx-submit="validate">
              <.live_file_input upload={@uploads.torrent} class="sr-only" />
              <label
                for={@uploads.torrent.ref}
                class="inline-flex h-9 cursor-pointer items-center rounded-md border border-transparent bg-primary px-4 text-sm font-semibold text-primary-content hover:brightness-110"
              >
                {gettext("Add torrent")}
              </label>
            </form>

            <.theme_toggle theme={@theme} locale={@locale} />

            <div class="tooltip tooltip-bottom" data-tip={gettext("Settings")}>
              <button
                type="button"
                id="open-settings"
                phx-click="open_settings"
                class={top_bar_icon_class()}
                aria-label={gettext("Settings")}
              >
                <.icon name="hero-cog-6-tooth" class="size-5" />
              </button>
            </div>

            <div class="tooltip tooltip-bottom" data-tip={gettext("Report a problem")}>
              <button
                type="button"
                id="open-report"
                phx-click="open_report"
                class={top_bar_icon_class()}
                aria-label={gettext("Report a problem")}
              >
                <.icon name="hero-flag" class="size-5" />
              </button>
            </div>
          </div>
        </div>

        <.default_handler_prompt status={@default_handler} dismissed={@default_prompt_dismissed} />

        <div class="space-y-3">
          <.torrent_card
            :for={torrent <- @torrents}
            torrent={torrent}
            expanded={MapSet.member?(@expanded, torrent.id)}
            locale={@locale}
          />

          <div class="rounded-2xl border border-dashed border-base-300 bg-base-200 px-6 py-10 text-center text-base-content/60">
            {gettext("Drag and drop a `.torrent` file here, or")}
            <label
              for={@uploads.torrent.ref}
              class="cursor-pointer text-primary underline"
            >
              {gettext("click to add")}
            </label>.
          </div>
        </div>

        <div
          :if={@torrents == []}
          class="rounded-xl border border-base-300 bg-base-200 px-4 py-8 text-center text-base-content/70"
        >
          {gettext("No active torrents. Add a `.torrent` file or magnet link to start downloading.")}
        </div>
      </div>

      <.remove_torrent_dialog dialog={@remove_dialog} />
      <.settings_dialog
        open={@settings_open}
        locale={@settings_locale}
        download_folder={@settings_download_folder}
        default_handler={@default_handler}
        languages={ElixirTorrentWebUI.Languages.list()}
      />
      <.report_dialog
        open={@report_open}
        form={@report_form}
        uploads={@uploads}
        issue_url={build_report_url(@report_form, assigns)}
      />
      <.media_player_modal player={@player} />
    </Layouts.app>

    <div
      id="drag-overlay"
      phx-hook=".DragOverlay"
      phx-update="ignore"
      data-drop-title={gettext("Drop files here!")}
      data-reject-title={gettext("This file type is not supported")}
      data-drop-hint={gettext("Only `.torrent` files accepted")}
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
          {gettext("Drop files here!")}
        </p>
        <p data-overlay-hint class="mt-2 text-sm text-base-content/70">
          {gettext("Only `.torrent` files accepted")}
        </p>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".PasteMagnet">
      export default {
        mounted() {
          this.el.addEventListener("click", () => this.readClipboard())
        },

        async readClipboard() {
          if (!navigator.clipboard?.readText) {
            this.pushEvent("add_magnet", { magnet: "", error: "clipboard" })
            return
          }

          try {
            const text = await navigator.clipboard.readText()
            this.pushEvent("add_magnet", { magnet: (text || "").trim() })
          } catch (_error) {
            this.pushEvent("add_magnet", { magnet: "", error: "clipboard" })
          }
        }
      }
    </script>

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
          const dropTitle = this.overlay.dataset.dropTitle
          const rejectTitle = this.overlay.dataset.rejectTitle
          if (!card) return
          if (accepted) {
            card.classList.remove("border-error")
            card.classList.add("border-primary")
            if (title) title.textContent = dropTitle
            if (hint) hint.classList.remove("text-error")
            if (okIcon) { okIcon.classList.remove("hidden"); okIcon.classList.add("block") }
            if (noIcon) { noIcon.classList.add("hidden"); noIcon.classList.remove("block") }
          } else {
            card.classList.add("border-error")
            card.classList.remove("border-primary")
            if (title) title.textContent = rejectTitle
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

  @spec assign_torrents(Phoenix.LiveView.Socket.t(), list(Engine.TorrentRow.t())) ::
          Phoenix.LiveView.Socket.t()
  defp assign_torrents(socket, torrents) do
    rates = Engine.aggregate_rates(torrents)
    all_time = StatsStore.get()

    stats = %Engine.AggregateStats{
      bytes_downloaded: all_time.total_downloaded,
      bytes_uploaded: all_time.total_uploaded,
      down_kbps: rates.down_kbps,
      up_kbps: rates.up_kbps
    }

    socket
    |> assign(:torrents, torrents)
    |> assign(:stats, stats)
  end

  @spec persist_upload(Path.t(), Phoenix.LiveView.UploadEntry.t()) :: Path.t()
  defp persist_upload(tmp_path, entry) do
    dir = Path.join(System.tmp_dir!(), "elixir_torrent_web_ui/uploads")
    File.mkdir_p!(dir)

    # The browser-supplied client name is display-only and must not become part
    # of a filesystem path. LiveView generates the UUID used for storage.
    filename = "#{entry.uuid}.torrent"
    dest = Path.join(dir, filename)
    File.cp!(tmp_path, dest)
    dest
  end

  attr :stats, Engine.AggregateStats, required: true

  defp aggregate_stats_bar(assigns) do
    ~H"""
    <div
      id="aggregate-stats"
      class="flex flex-wrap items-end justify-center gap-x-3 gap-y-1 text-xs tabular-nums text-base-content/80 sm:gap-x-4 sm:text-sm"
      aria-label={gettext("Transfer statistics")}
    >
      <div class="flex flex-col items-center gap-0.5">
        <span class="text-[10px] font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Downloaded")}
        </span>
        <span
          class="inline-flex items-center gap-1 text-success"
          title={gettext("All-time bytes downloaded")}
        >
          ↓ {format_bytes(@stats.bytes_downloaded)}
        </span>
      </div>
      <div class="flex flex-col items-center gap-0.5">
        <span class="text-[10px] font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Uploaded")}
        </span>
        <span
          class="inline-flex items-center gap-1 text-secondary"
          title={gettext("All-time bytes uploaded")}
        >
          ↑ {format_bytes(@stats.bytes_uploaded)}
        </span>
      </div>
      <span class="hidden pb-0.5 text-base-content/40 sm:inline" aria-hidden="true">|</span>
      <div class="flex flex-col items-center gap-0.5">
        <span class="text-[10px] font-medium uppercase tracking-wide text-base-content/50">
          {gettext("Speed")}
        </span>
        <div class="inline-flex items-center gap-2">
          <span
            class="inline-flex items-center gap-1 text-success"
            title={gettext("Current download speed")}
          >
            ↓ {format_speed(@stats.down_kbps)}
          </span>
          <span
            class="inline-flex items-center gap-1 text-secondary"
            title={gettext("Current upload speed")}
          >
            ↑ {format_speed(@stats.up_kbps)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :torrent, Engine.TorrentRow, required: true
  attr :expanded, :boolean, required: true
  attr :locale, :string, required: true

  @doc false
  def torrent_card(assigns) do
    ~H"""
    <div
      id={"torrent-#{@torrent.id}-#{@locale}"}
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
            {translate_status(@torrent.status)}
          </p>
        </div>
        <div class="mt-1 flex shrink-0 items-center gap-1">
          <div class="tooltip tooltip-top" data-tip={gettext("Report a problem")}>
            <button
              type="button"
              id={"torrent-report-#{@torrent.id}"}
              phx-click="open_report"
              phx-value-torrent_id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
              aria-label={gettext("Report a problem")}
            >
              <.icon name="hero-flag" class="size-5" />
            </button>
          </div>
          <div class="tooltip tooltip-top" data-tip={gettext("Show Folder")}>
            <button
              type="button"
              id={"torrent-folder-#{@torrent.id}"}
              phx-click="show_folder"
              phx-value-id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
              aria-label={gettext("Show Folder")}
            >
              <.icon name="hero-folder-open" class="size-5" />
            </button>
          </div>
          <div class="tooltip tooltip-top" data-tip={gettext("Remove Torrent")}>
            <button
              type="button"
              id={"torrent-remove-#{@torrent.id}"}
              phx-click="open_remove_dialog"
              phx-value-id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-error"
              aria-label={gettext("Remove Torrent")}
            >
              <.icon name="hero-trash" class="size-5" />
            </button>
          </div>
          <div
            class="tooltip tooltip-top"
            data-tip={
              if(@expanded, do: gettext("Hide Torrent Files"), else: gettext("Show Torrent Files"))
            }
          >
            <button
              type="button"
              id={"torrent-expand-#{@torrent.id}"}
              phx-click="toggle_expand"
              phx-value-id={@torrent.id}
              class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/70 transition hover:bg-base-300 hover:text-base-content"
              aria-expanded={to_string(@expanded)}
              aria-controls={"torrent-files-#{@torrent.id}"}
              aria-label={
                if(@expanded, do: gettext("Hide Torrent Files"), else: gettext("Show Torrent Files"))
              }
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
                  {gettext("Date Added")}
                </p>
                <p class="mt-1 tabular-nums">{format_date(@torrent.added_at)}</p>
              </div>
              <div class="shrink-0">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  {gettext("Total Files")}
                </p>
                <p class="mt-1 tabular-nums">{@torrent.file_count}</p>
              </div>
              <div class="shrink-0">
                <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
                  {gettext("Total Size")}
                </p>
                <p class="mt-1 tabular-nums">{format_bytes(@torrent.bytes_size)}</p>
              </div>
            </div>

            <div class="min-w-0 w-full">
              <div class="w-full overflow-hidden rounded-xl border border-base-300">
                <div class="grid grid-cols-[minmax(0,1fr)_5rem_6rem] gap-3 border-b border-base-300 bg-base-300/50 px-4 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  <span>{gettext("Name")}</span>
                  <span class="text-right">{gettext("Size")}</span>
                  <span class="text-right">{gettext("Download")}</span>
                </div>
                <div
                  :for={file <- @torrent.files}
                  id={"torrent-file-#{@torrent.id}-#{file.index}"}
                  class={[
                    "grid grid-cols-[minmax(0,1fr)_5rem_6rem] gap-3 border-b border-base-300/70 px-4 py-3 text-sm last:border-b-0 transition-colors hover:bg-base-300/70",
                    file_action(file) && "group cursor-pointer"
                  ]}
                  phx-click={file_action(file)}
                  phx-value-torrent_id={@torrent.id}
                  phx-value-file_index={file.index}
                  aria-label={file_aria_label(file)}
                >
                  <div class="flex min-w-0 items-center gap-3">
                    <.torrent_file_leading file={file} torrent_id={@torrent.id} />
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
                        <span class="sr-only">{gettext("Downloaded")}</span>
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

  attr :file, Engine.FileRow, required: true
  attr :torrent_id, :string, required: true

  @doc false
  def torrent_file_leading(assigns) do
    ~H"""
    <%= cond do %>
      <% Engine.playable_file?(@file) -> %>
        <span
          id={"torrent-file-play-#{@torrent_id}-#{@file.index}"}
          class="inline-flex size-9 shrink-0 items-center justify-center rounded-full border-2 border-base-content bg-transparent text-base-content transition group-hover:border-success group-hover:bg-success group-hover:text-white"
          aria-hidden="true"
        >
          <.icon name="hero-play" class="size-4 translate-x-px" />
        </span>
      <% Engine.previewable_image?(@file) -> %>
        <span
          id={"torrent-file-image-#{@torrent_id}-#{@file.index}"}
          class="inline-flex size-9 shrink-0 overflow-hidden rounded-md border border-base-300 bg-base-300/40"
          aria-hidden="true"
        >
          <img
            src={~p"/media/#{@torrent_id}/#{@file.index}/preview"}
            alt=""
            loading="lazy"
            decoding="async"
            class="size-full object-cover"
          />
        </span>
      <% Engine.openable_image?(@file) -> %>
        <span
          id={"torrent-file-image-#{@torrent_id}-#{@file.index}"}
          class="inline-flex size-9 shrink-0 items-center justify-center rounded-md border border-base-300 bg-base-300/40 text-base-content/70"
          aria-hidden="true"
        >
          <.icon name="hero-photo" class="size-5" />
        </span>
      <% true -> %>
    <% end %>
    """
  end

  defp file_action(file) do
    cond do
      Engine.playable_file?(file) -> "open_player"
      Engine.openable_image?(file) -> "open_image"
      true -> nil
    end
  end

  defp file_aria_label(file) do
    cond do
      Engine.playable_file?(file) -> gettext("Play %{name}", name: file.name)
      Engine.openable_image?(file) -> gettext("Open image %{name}", name: file.name)
      true -> nil
    end
  end

  attr :player, :map, default: nil

  @doc false
  def media_player_modal(assigns) do
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
        aria-label={gettext("Close player")}
      />
      <div class="relative z-10 max-h-[calc(100dvh-2rem)] overflow-y-auto w-full max-w-5xl rounded-2xl border border-base-300 bg-base-100 p-4 shadow-2xl sm:p-6">
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
            aria-label={gettext("Close")}
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

  attr :open, :boolean, default: false
  attr :locale, :string, required: true
  attr :download_folder, :string, required: true
  attr :default_handler, :map, required: true
  attr :languages, :list, required: true

  @doc false
  def settings_dialog(assigns) do
    ~H"""
    <div
      :if={@open}
      id="settings-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-dialog-title"
    >
      <button
        type="button"
        id="settings-dialog-backdrop"
        phx-click="close_settings"
        class="absolute inset-0 cursor-default bg-black/50"
        aria-label={gettext("Cancel")}
      />
      <form
        id="settings-form"
        phx-submit="apply_settings"
        phx-change="settings_locale_changed"
        class="relative z-10 max-h-[calc(100dvh-2rem)] overflow-y-auto w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl"
      >
        <div class="flex items-start justify-between gap-4">
          <h2 id="settings-dialog-title" class="text-xl font-semibold text-base-content">
            {gettext("Settings")}
          </h2>
          <button
            type="button"
            id="settings-dialog-close"
            phx-click="close_settings"
            class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
            aria-label={gettext("Cancel")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div
          :if={default_handler_banner?(@default_handler)}
          id="settings-default-handler-banner"
          class="mt-6 rounded-lg border-2 border-warning/60 bg-warning/15 px-4 py-3"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="flex min-w-0 flex-1 items-start gap-3">
              <.icon
                name="hero-exclamation-triangle"
                class="mt-0.5 size-5 shrink-0 text-warning"
              />
              <div class="min-w-0">
                <p class="text-sm font-semibold text-base-content">
                  {gettext("Make ElixirTorrent Web your default torrent app")}
                </p>
                <p class="mt-1 text-xs text-base-content/70">
                  {gettext(
                    "Set as the default program for .torrent files and magnet links so double-clicking or clicking a link opens them here."
                  )}
                </p>
              </div>
            </div>
            <button
              type="button"
              id="settings-default-handler-set"
              phx-click="request_default_handler"
              class="inline-flex h-9 shrink-0 cursor-pointer items-center rounded-md border border-transparent bg-warning px-4 text-sm font-semibold text-warning-content hover:brightness-110"
            >
              {gettext("Set as default")}
            </button>
          </div>
        </div>

        <div class="mt-6">
          <label for="settings-locale" class="mb-2 block text-sm font-medium text-base-content">
            {gettext("Language")}
          </label>
          <select
            id="settings-locale"
            name="locale"
            class="select select-bordered w-full bg-base-100 text-base-content"
          >
            <option
              :for={lang <- @languages}
              value={lang.code}
              selected={lang.code == @locale}
            >
              {ElixirTorrentWebUI.Languages.picker_label(lang)}
            </option>
          </select>
        </div>

        <div class="mt-6">
          <p class="mb-2 text-sm font-medium text-base-content">
            {gettext("Default download folder")}
          </p>
          <div class="flex items-center gap-3 rounded-lg border border-base-300 bg-base-200/40 px-3 py-2.5">
            <p
              id="settings-download-folder-path"
              class="min-w-0 flex-1 truncate text-sm text-base-content/80"
              title={@download_folder}
            >
              {@download_folder}
            </p>
            <button
              type="button"
              id="settings-download-folder-change"
              phx-click="choose_download_folder"
              class="inline-flex shrink-0 cursor-pointer items-center rounded-md border border-transparent bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110"
            >
              {gettext("Change")}
            </button>
          </div>
        </div>

        <div class="mt-6 rounded-lg border border-base-300 bg-base-200/40 px-3 py-3">
          <p class="text-sm font-medium text-base-content">
            {gettext("Lifetime transfer statistics")}
          </p>
          <p class="mt-1 text-xs text-base-content/60">
            {gettext("Reset downloaded and uploaded totals for this device.")}
          </p>
          <button
            type="button"
            id="settings-reset-statistics"
            phx-click="reset_statistics"
            data-confirm={gettext("Reset lifetime transfer statistics?")}
            class="mt-3 inline-flex cursor-pointer items-center rounded-md border border-error/50 bg-base-100 px-4 py-2 text-sm font-semibold text-error transition hover:bg-error hover:text-error-content"
          >
            {gettext("Reset Statistics")}
          </button>
        </div>

        <div class="mt-6 flex flex-wrap justify-end gap-3">
          <button
            type="button"
            id="settings-cancel"
            phx-click="close_settings"
            class="inline-flex cursor-pointer items-center rounded-lg border border-base-300 bg-base-100 px-5 py-2.5 text-sm font-semibold text-base-content transition hover:bg-base-300/40"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            id="settings-apply"
            class="inline-flex cursor-pointer items-center rounded-lg bg-primary px-5 py-2.5 text-sm font-semibold text-primary-content transition hover:brightness-110"
          >
            {gettext("Apply")}
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :open, :boolean, default: false
  attr :form, :map, required: true
  attr :uploads, :map, required: true
  attr :issue_url, :string, required: true

  @doc false
  def report_dialog(assigns) do
    ~H"""
    <div
      :if={@open}
      id="report-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="report-dialog-title"
    >
      <button
        type="button"
        id="report-dialog-backdrop"
        phx-click="close_report"
        class="absolute inset-0 cursor-default bg-black/50"
        aria-label={gettext("Cancel")}
      />
      <form
        id="report-form"
        phx-change="update_report"
        phx-submit="update_report"
        class="relative z-10 flex max-h-[90vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
      >
        <div class="flex items-start justify-between gap-4 border-b border-base-300 px-6 py-4">
          <h2 id="report-dialog-title" class="text-xl font-semibold text-base-content">
            {gettext("Report a problem")}
          </h2>
          <button
            type="button"
            id="report-dialog-close"
            phx-click="close_report"
            class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
            aria-label={gettext("Cancel")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div class="flex-1 space-y-5 overflow-y-auto px-6 py-5">
          <div>
            <label for="report-category" class="mb-2 block text-sm font-medium text-base-content">
              {gettext("What kind of problem?")}
            </label>
            <select
              id="report-category"
              name="category"
              class="select select-bordered w-full bg-base-100 text-base-content"
            >
              <option value="" selected={@form.category in [nil, ""]}>
                {gettext("Choose a category…")}
              </option>
              <option
                :for={cat <- IssueReport.categories()}
                value={cat.id}
                selected={cat.id == @form.category}
              >
                {translate_report_category(cat.id)}
              </option>
            </select>
          </div>

          <div>
            <label
              for="report-description"
              class="mb-2 block text-sm font-medium text-base-content"
            >
              {gettext("Describe what happened")}
            </label>
            <textarea
              id="report-description"
              name="description"
              rows="5"
              placeholder={
                gettext("What did you do, what did you expect, and what happened instead?")
              }
              class="textarea textarea-bordered w-full bg-base-100 text-base-content"
            >{@form.description}</textarea>
          </div>

          <div class="rounded-lg border border-base-300 bg-base-200/40 p-4">
            <p class="text-sm font-medium text-base-content">
              {gettext("Attach a torrent (optional)")}
            </p>
            <p class="mt-1 text-xs text-base-content/60">
              {gettext(
                "Attach a .torrent file or paste a magnet link so we can reproduce the problem."
              )}
            </p>

            <div
              :if={@form.torrent_context}
              class="mt-3 rounded-md border border-base-300 bg-base-100 p-3 text-xs text-base-content/80"
            >
              <p class="font-semibold text-base-content">
                {gettext("From this torrent")}
              </p>
              <p class="mt-1 truncate" title={@form.torrent_context.name}>
                {@form.torrent_context.name}
              </p>
              <p class="mt-1 font-mono text-[10px] text-base-content/60">
                {@form.torrent_context.info_hash_hex}
              </p>
            </div>

            <div :if={!@form.torrent_context} class="mt-3 space-y-3">
              <div>
                <label class="mb-1 block text-xs font-medium text-base-content/70">
                  {gettext("Upload .torrent")}
                </label>
                <div
                  :if={@form.torrent_summary}
                  class="flex items-center justify-between gap-3 rounded-md border border-base-300 bg-base-100 p-3 text-xs"
                >
                  <div class="min-w-0">
                    <p
                      class="truncate font-medium text-base-content"
                      title={@form.torrent_summary.name}
                    >
                      {@form.torrent_summary.name}
                    </p>
                    <p class="mt-0.5 font-mono text-[10px] text-base-content/60">
                      {@form.torrent_summary.info_hash_hex}
                    </p>
                  </div>
                  <button
                    type="button"
                    id="report-torrent-clear"
                    phx-click="clear_report_torrent"
                    class="inline-flex shrink-0 cursor-pointer items-center rounded-md border border-base-300 bg-base-100 px-2.5 py-1 text-xs font-medium text-base-content transition hover:bg-base-300/40"
                  >
                    {gettext("Remove")}
                  </button>
                </div>

                <div :if={!@form.torrent_summary} phx-change="validate_report_torrent">
                  <.live_file_input upload={@uploads.report_torrent} class="sr-only" />
                  <label
                    for={@uploads.report_torrent.ref}
                    class="mt-1 inline-flex cursor-pointer items-center rounded-md border border-base-300 bg-base-100 px-3 py-2 text-xs font-medium text-base-content transition hover:bg-base-300/40"
                  >
                    {gettext("Choose .torrent…")}
                  </label>
                </div>
              </div>

              <div>
                <label
                  for="report-magnet"
                  class="mb-1 block text-xs font-medium text-base-content/70"
                >
                  {gettext("or paste a magnet link")}
                </label>
                <input
                  id="report-magnet"
                  name="magnet"
                  type="text"
                  value={@form.magnet || ""}
                  placeholder="magnet:?xt=urn:btih:…"
                  class="input input-bordered w-full bg-base-100 text-xs font-mono text-base-content"
                />
              </div>
            </div>
          </div>

          <details class="rounded-lg border border-base-300 bg-base-200/40 px-4 py-3">
            <summary class="cursor-pointer text-sm font-medium text-base-content">
              {gettext("Preview what will be sent")}
            </summary>
            <pre
              id="report-preview"
              class="mt-3 max-h-64 overflow-auto rounded-md border border-base-300 bg-base-100 p-3 text-xs leading-relaxed text-base-content/80"
            ><code>{@issue_url}</code></pre>
            <p class="mt-2 text-xs text-base-content/60">
              {gettext(
                "Nothing is sent from this app. Clicking Open GitHub opens the URL in your browser so you can review and submit."
              )}
            </p>
          </details>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 bg-base-200/60 px-6 py-4">
          <p class="text-xs text-base-content/60">
            {gettext("You'll review the issue in GitHub before it's created.")}
          </p>
          <div class="flex flex-wrap items-center gap-3">
            <button
              type="button"
              id="report-cancel"
              phx-click="close_report"
              class="inline-flex cursor-pointer items-center rounded-lg border border-base-300 bg-base-100 px-5 py-2.5 text-sm font-semibold text-base-content transition hover:bg-base-300/40"
            >
              {gettext("Cancel")}
            </button>
            <a
              id="report-submit"
              href={@issue_url}
              target="_blank"
              rel="noopener noreferrer"
              phx-click={JS.push("close_report")}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-lg bg-primary px-5 py-2.5 text-sm font-semibold text-primary-content transition hover:brightness-110"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              {gettext("Open GitHub issue")}
            </a>
          </div>
        </div>
      </form>
    </div>
    """
  end

  attr :dialog, :map, default: nil

  @doc false
  def remove_torrent_dialog(assigns) do
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
        aria-label={gettext("Close dialog")}
      />
      <div class="relative z-10 max-h-[calc(100dvh-2rem)] overflow-y-auto w-full max-w-lg rounded-2xl border border-base-300 bg-base-100 p-6 shadow-2xl">
        <div class="flex items-start justify-between gap-4">
          <h2 id="remove-torrent-dialog-title" class="text-xl font-semibold text-[#d15555]">
            {gettext("Remove Torrent?")}
          </h2>
          <button
            type="button"
            id="remove-torrent-dialog-close"
            phx-click="close_remove_dialog"
            class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <p class="mt-4 text-sm text-base-content/80">
          {gettext("Are you sure you want to remove the selected torrent?")}
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
            {gettext("Remove Torrent")}
          </button>
          <button
            type="button"
            id="remove-torrent-confirm-data"
            phx-click="confirm_remove"
            phx-value-delete_data="true"
            class="inline-flex cursor-pointer items-center rounded-lg bg-[#d15555] px-5 py-2.5 text-sm font-semibold text-white transition hover:brightness-110"
          >
            {gettext("Remove Torrent + Data")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  @spec removed_flash(String.t(), boolean()) :: String.t()
  defp removed_flash(name, true),
    do: gettext("Removed torrent and data: %{name}", name: name)

  defp removed_flash(name, false), do: gettext("Removed torrent: %{name}", name: name)

  # `DefaultHandler.request_default/0` can return before the platform's own
  # default-handler database has caught up — on macOS, LaunchServices can
  # still report the old handler to a process spawned right after
  # registration succeeds (see `registerAsDefault()` in
  # `priv/macos/src/DefaultHandlerCoordinator.swift`), sometimes for seconds under contention from
  # other registered torrent clients; on Windows the user has to confirm the
  # change in a system dialog. Rather than re-invoking `DefaultHandler.status/0`
  # on a timer and hoping we ask again after it flips, hand the wait to
  # `DefaultHandler.await_default/0`, which blocks *inside the launcher
  # process* until the OS actually reflects the change (or gives up after a
  # generous timeout) — a genuine notification from the platform layer. It
  # has to run via `start_async/3`: it blocks for however long that takes, and
  # this is a LiveView event handler, so it must not block the socket itself.
  @spec await_default_handler(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp await_default_handler(socket) do
    start_async(socket, :await_default_handler, fn -> DefaultHandler.await_default() end)
  end

  @impl Phoenix.LiveView
  def handle_async(:await_default_handler, {:ok, status}, socket) do
    {:noreply, assign(socket, :default_handler, status)}
  end

  def handle_async(:await_default_handler, {:exit, reason}, socket) do
    Logger.warning("TorrentsLive: await_default_handler task exited reason=#{inspect(reason)}")
    {:noreply, socket}
  end

  @spec default_handler_banner?(DefaultHandler.status()) :: boolean()
  defp default_handler_banner?(status), do: DefaultHandler.needs_prompt?(status)

  # The packaged app also raises a native alert on launch, but that one only
  # exists in the bundle. This in-page prompt is what the user meets on every
  # open — including in development — and it stays dismissed for the session.
  @spec default_handler_prompt?(DefaultHandler.status(), boolean()) :: boolean()
  defp default_handler_prompt?(_status, true), do: false
  defp default_handler_prompt?(status, false), do: DefaultHandler.needs_prompt?(status)

  attr :status, :map, required: true
  attr :dismissed, :boolean, required: true

  @doc false
  def default_handler_prompt(assigns) do
    ~H"""
    <div
      :if={default_handler_prompt?(@status, @dismissed)}
      id="default-handler-prompt"
      class="flex flex-wrap items-start justify-between gap-3 rounded-xl border-2 border-warning/60 bg-warning/15 px-4 py-3"
    >
      <div class="flex min-w-0 flex-1 items-start gap-3">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
        <div class="min-w-0">
          <p class="text-sm font-semibold text-base-content">
            {gettext("Make ElixirTorrent Web your default torrent app")}
          </p>
          <p class="mt-1 text-xs text-base-content/70">
            {gettext(
              "Set as the default program for .torrent files and magnet links so double-clicking or clicking a link opens them here."
            )}
          </p>
        </div>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <button
          type="button"
          id="default-handler-prompt-set"
          phx-click="request_default_handler"
          class="inline-flex h-9 cursor-pointer items-center rounded-md border border-transparent bg-warning px-4 text-sm font-semibold text-warning-content hover:brightness-110"
        >
          {gettext("Set as default")}
        </button>
        <button
          type="button"
          id="default-handler-prompt-dismiss"
          phx-click="dismiss_default_prompt"
          class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-base-content/60 transition hover:bg-base-300 hover:text-base-content"
          aria-label={gettext("Cancel")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @spec empty_report_form() :: map()
  defp empty_report_form do
    %{
      category: nil,
      description: "",
      magnet: nil,
      torrent_summary: nil,
      torrent_context: nil
    }
  end

  defp nilify_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nilify_blank(_), do: nil

  @spec reset_report_upload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp reset_report_upload(socket) do
    Enum.reduce(socket.assigns.uploads.report_torrent.entries, socket, fn entry, acc ->
      cancel_upload(acc, :report_torrent, entry.ref)
    end)
  end

  @spec torrent_row_to_context(Engine.TorrentRow.t() | nil) ::
          ElixirTorrentWebUI.IssueReport.torrent_context() | nil
  defp torrent_row_to_context(nil), do: nil

  defp torrent_row_to_context(%Engine.TorrentRow{} = row) do
    %{
      name: row.name,
      info_hash_hex: row.id,
      progress_percent: row.progress,
      status: row.status,
      peers: row.peers,
      down_kbps: row.down_kbps,
      up_kbps: row.up_kbps,
      bytes_downloaded: row.bytes_downloaded,
      bytes_size: row.bytes_size
    }
  end

  @spec app_context(map()) :: ElixirTorrentWebUI.IssueReport.app_context()
  defp app_context(assigns) do
    {os_family, os_name} = :os.type()

    %{
      version: to_string(Application.spec(:elixir_torrent_web_ui, :vsn) || "unknown"),
      os: "#{os_family}/#{os_name}",
      locale: to_string(assigns.locale),
      theme: to_string(assigns.theme)
    }
  end

  @spec build_report_url(map(), map()) :: String.t()
  defp build_report_url(form, assigns) do
    form
    |> Map.put(:app_context, app_context(assigns))
    |> IssueReport.build()
    |> IssueReport.url()
  end

  @spec translate_status(String.t()) :: String.t()
  defp translate_status("Seeding"), do: gettext("Seeding")
  defp translate_status("Connecting"), do: gettext("Connecting")
  defp translate_status("Idle"), do: gettext("Idle")
  defp translate_status("Downloading"), do: gettext("Downloading")
  defp translate_status(status), do: status

  @spec translate_report_category(String.t()) :: String.t()
  defp translate_report_category("not-downloading"), do: gettext("Torrent is not downloading")
  defp translate_report_category("stuck"), do: gettext("Torrent is stuck or looping")
  defp translate_report_category("no-peers"), do: gettext("No peers are found")
  defp translate_report_category("metadata"), do: gettext("Metadata never arrives")
  defp translate_report_category("playback"), do: gettext("Play or preview does not work")
  defp translate_report_category("crash"), do: gettext("App crashed or froze")
  defp translate_report_category("ui"), do: gettext("UI glitch or wrong translation")
  defp translate_report_category("other"), do: gettext("Something else")
  defp translate_report_category(other), do: other

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
  attr :locale, :string, required: true

  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  defp theme_toggle(assigns) do
    ~H"""
    <div class="tooltip tooltip-bottom" data-tip={gettext("Toggle theme")}>
      <button
        type="button"
        id="toggle-theme"
        phx-click="toggle_theme"
        class={top_bar_icon_class()}
        aria-label={gettext("Toggle theme")}
      >
        <.icon name="hero-sun-mini" class={["size-5", @theme == "light" && "hidden"]} />
        <.icon name="hero-moon-mini" class={["size-5", @theme == "dark" && "hidden"]} />
      </button>
    </div>
    """
  end

  # Shared chrome for the icon-only top-bar buttons. `size-9` matches the 36px
  # height of the labelled `Paste magnet & Go` / `Add torrent` buttons so the
  # whole row lines up, and every one of them carries its label in a tooltip.
  @spec top_bar_icon_class() :: String.t()
  defp top_bar_icon_class do
    "inline-flex size-9 cursor-pointer items-center justify-center rounded-md " <>
      "border border-base-300 bg-base-100 text-base-content transition hover:bg-base-300/40"
  end
end
