defmodule ElixirTorrentWebUIWeb.Router do
  use ElixirTorrentWebUIWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ElixirTorrentWebUIWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ElixirTorrentWebUIWeb.Plugs.SetLocale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ElixirTorrentWebUIWeb do
    pipe_through :browser

    live_session :default, on_mount: {ElixirTorrentWebUIWeb.LocaleHook, :default} do
      live "/", TorrentsLive
    end

    get "/locale/:locale", LocaleController, :update
    get "/media/:torrent_id/:file_index", MediaController, :show
  end

  scope "/api", ElixirTorrentWebUIWeb do
    pipe_through :api

    get "/torrents", TorrentController, :index
    post "/magnets", MagnetController, :create
    post "/torrents", TorrentController, :create
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:elixir_torrent_web_ui, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ElixirTorrentWebUIWeb.Telemetry
    end
  end
end
