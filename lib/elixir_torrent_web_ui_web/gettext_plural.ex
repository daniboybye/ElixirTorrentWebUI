defmodule ElixirTorrentWebUIWeb.GettextPlural do
  @moduledoc false

  @behaviour Gettext.Plural

  # Gettext 1.0 does not ship plural rules for Tagalog (tl); treat like English.
  def nplurals("tl"), do: 2
  def plural("tl", 1), do: 0
  def plural("tl", _), do: 1

  defdelegate nplurals(locale), to: Gettext.Plural
  defdelegate plural(locale, n), to: Gettext.Plural
end
