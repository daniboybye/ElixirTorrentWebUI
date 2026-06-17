defmodule ElixirTorrentWebUIWeb.LocaleHook do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias ElixirTorrentWebUI.{Locale, UiState}

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    locale =
      session
      |> resolve_locale()
      |> Locale.put()

    socket =
      socket
      |> assign(:locale, locale)

    socket =
      if connected?(socket) do
        push_event(socket, "set-locale", %{locale: locale})
      else
        socket
      end

    {:cont, socket}
  end

  @spec resolve_locale(map()) :: String.t()
  defp resolve_locale(session) do
    case Map.get(session, "locale") do
      nil -> UiState.get().locale
      locale -> locale
    end
    |> Locale.normalize()
  end
end
