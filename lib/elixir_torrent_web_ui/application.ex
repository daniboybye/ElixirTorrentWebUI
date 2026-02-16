defmodule ElixirTorrentWebUI.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure the BitTorrent engine (from ../ElixirTorrent) is running.
    # We keep the UI app responsible for starting/stopping the engine.
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)

    children = [
      ElixirTorrentWebUIWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:elixir_torrent_web_ui, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirTorrentWebUI.PubSub},
      # Start a worker by calling: ElixirTorrentWebUI.Worker.start_link(arg)
      # {ElixirTorrentWebUI.Worker, arg},
      # Start to serve requests, typically the last entry
      ElixirTorrentWebUIWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirTorrentWebUI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ElixirTorrentWebUIWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
