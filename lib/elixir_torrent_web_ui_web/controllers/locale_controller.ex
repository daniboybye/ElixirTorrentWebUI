defmodule ElixirTorrentWebUIWeb.LocaleController do
  use ElixirTorrentWebUIWeb, :controller

  alias ElixirTorrentWebUI.{Locale, UiState}

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"locale" => locale}) do
    locale = Locale.normalize(locale)
    :ok = UiState.put_locale(locale)

    conn
    |> put_session(:locale, locale)
    |> redirect(to: ~p"/")
  end
end
