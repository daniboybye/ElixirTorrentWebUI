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
      ElixirTorrentWebUI.TorrentCatalog,
      ElixirTorrentWebUI.UiState,
      ElixirTorrentWebUIWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:elixir_torrent_web_ui, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirTorrentWebUI.PubSub},
      ElixirTorrentWebUIWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ElixirTorrentWebUI.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      ElixirTorrentWebUI.TorrentCatalog.restore_torrents()
      {:ok, pid}
    end
  end

  @impl true
  def stop(_state) do
    ElixirTorrentWebUI.TorrentCatalog.persist_state()
    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ElixirTorrentWebUIWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
