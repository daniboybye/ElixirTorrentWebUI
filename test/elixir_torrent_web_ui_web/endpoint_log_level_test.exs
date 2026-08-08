defmodule ElixirTorrentWebUIWeb.EndpointLogLevelTest do
  # Mutates the global Logger level, so it must not run alongside other tests.
  use ElixirTorrentWebUIWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ElixirTorrentWebUIWeb.Endpoint

  setup do
    previous = Logger.level()
    :ok = Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "the launcher's Dock poll is demoted below the production log level" do
    conn = %Plug.Conn{method: "GET", path_info: ["api", "torrents"]}

    assert Endpoint.request_log_level(conn) == :debug
  end

  test "requests that are not the Dock poll keep the default level" do
    for {method, path} <- [
          {"POST", ["api", "torrents"]},
          {"POST", ["api", "magnets"]},
          {"GET", []},
          {"GET", ["media", "abc", "0"]}
        ] do
      conn = %Plug.Conn{method: method, path_info: path}

      assert Endpoint.request_log_level(conn) == :info,
             "expected #{method} /#{Enum.join(path, "/")} to stay at :info"
    end
  end

  test "polling /api/torrents writes nothing at the production log level", %{conn: conn} do
    logs = capture_log([level: :info], fn -> get(conn, ~p"/api/torrents") end)

    refute logs =~ "GET /api/torrents"
    refute logs =~ "Sent 200"
  end

  test "the same poll is still visible when debugging", %{conn: conn} do
    logs = capture_log([level: :debug], fn -> get(conn, ~p"/api/torrents") end)

    assert logs =~ "GET /api/torrents"
    assert logs =~ "Sent 200"
  end

  test "ordinary requests still log at the production level", %{conn: conn} do
    logs = capture_log([level: :info], fn -> get(conn, ~p"/") end)

    assert logs =~ "GET /"
    assert logs =~ "Sent 200"
  end
end
