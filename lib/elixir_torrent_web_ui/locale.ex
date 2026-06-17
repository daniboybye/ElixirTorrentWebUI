defmodule ElixirTorrentWebUI.Locale do
  @moduledoc false

  alias ElixirTorrentWebUI.Languages

  @spec put(String.t()) :: String.t()
  def put(locale) when is_binary(locale) do
    locale = normalize(locale)
    Gettext.put_locale(ElixirTorrentWebUIWeb.Gettext, locale)
    locale
  end

  @spec sync(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sync(%{assigns: %{locale: locale}} = socket) do
    _ = put(locale)
    socket
  end

  @spec normalize(String.t()) :: String.t()
  def normalize(locale) do
    if Languages.valid?(locale), do: locale, else: Languages.default()
  end
end
