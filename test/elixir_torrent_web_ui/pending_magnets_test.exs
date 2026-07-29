defmodule ElixirTorrentWebUI.PendingMagnetsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirTorrentWebUI.PendingMagnets

  @magnet "magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&dn=Fixture"
  @id "0123456789ABCDEF0123456789ABCDEF01234567"

  setup do
    :ok = PendingMagnets.remove(@id)
    on_exit(fn -> PendingMagnets.remove(@id) end)
    :ok
  end

  test "registers valid magnets and persists resumable state" do
    assert :ok = PendingMagnets.register(@magnet)

    assert [
             %{
               id: @id,
               uri: @magnet,
               name: "Fixture",
               stage: "fetching"
             }
           ] = Enum.filter(PendingMagnets.entries(), &(&1.id == @id))

    assert {:ok, %{"magnets" => persisted}} =
             PendingMagnets.path()
             |> File.read!()
             |> Jason.decode()

    assert Enum.any?(persisted, &(&1["id"] == @id and &1["uri"] == @magnet))
  end

  test "rejects malformed magnets without adding state" do
    secret = "not-a-magnet-with-private-tracker-passkey"

    log =
      capture_log(fn ->
        assert {:error, _reason} = PendingMagnets.register(secret)
      end)

    assert log =~ "register_skip"
    refute log =~ secret
    refute Enum.any?(PendingMagnets.entries(), &(&1.uri == secret))
  end

  test "removes a pending magnet by URI" do
    assert :ok = PendingMagnets.register(@magnet)
    assert :ok = PendingMagnets.remove_by_uri(@magnet)
    refute Enum.any?(PendingMagnets.entries(), &(&1.id == @id))
  end
end
