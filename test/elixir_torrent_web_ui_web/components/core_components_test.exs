defmodule ElixirTorrentWebUIWeb.CoreComponentsTest do
  use ElixirTorrentWebUIWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElixirTorrentWebUIWeb.CoreComponents

  @unbreakable "Some.Release.Name.Without.Any.Spaces.2026.2160p.WEB-DL.DDP5.1.HDR.x265-GROUP"

  setup do
    ElixirTorrentWebUI.Locale.put("en")
    :ok
  end

  for kind <- [:info, :error] do
    test "#{kind} flash keeps an unbreakable long message inside the toast" do
      kind = unquote(kind)

      classes =
        render_component(&CoreComponents.flash/1,
          kind: kind,
          flash: %{Atom.to_string(kind) => "Torrent added: #{@unbreakable}"}
        )
        |> message_container(kind)
        |> LazyHTML.attribute("class")
        |> List.first()
        |> String.split()

      assert "wrap-anywhere" in classes
      assert "min-w-0" in classes
    end
  end

  test "flash still renders the full message text" do
    html =
      render_component(&CoreComponents.flash/1,
        kind: :info,
        flash: %{"info" => "Torrent added: #{@unbreakable}"}
      )

    text =
      html
      |> message_container(:info)
      |> LazyHTML.text()

    assert text =~ @unbreakable
  end

  defp message_container(html, kind) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-#{kind}-message")
  end
end
