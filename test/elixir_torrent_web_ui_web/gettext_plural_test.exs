defmodule ElixirTorrentWebUIWeb.GettextPluralTest do
  use ExUnit.Case, async: true

  alias ElixirTorrentWebUIWeb.GettextPlural

  test "uses two English-like plural forms for Tagalog" do
    assert GettextPlural.nplurals("tl") == 2
    assert GettextPlural.plural("tl", 1) == 0
    assert GettextPlural.plural("tl", 0) == 1
    assert GettextPlural.plural("tl", 2) == 1
  end

  test "delegates other locales to Gettext plural rules" do
    assert GettextPlural.nplurals("en") == Gettext.Plural.nplurals("en")
    assert GettextPlural.plural("bg", 2) == Gettext.Plural.plural("bg", 2)
  end
end
