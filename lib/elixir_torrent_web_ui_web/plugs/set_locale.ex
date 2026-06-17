defmodule ElixirTorrentWebUIWeb.Plugs.SetLocale do
  @moduledoc false

  import Plug.Conn

  alias ElixirTorrentWebUI.{Locale, UiState}

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    locale =
      conn
      |> get_session(:locale)
      |> resolve_locale()

    _ = Locale.put(locale)
    conn
  end

  @spec resolve_locale(String.t() | nil) :: String.t()
  defp resolve_locale(nil), do: UiState.get().locale |> Locale.normalize()
  defp resolve_locale(locale), do: Locale.normalize(locale)
end
