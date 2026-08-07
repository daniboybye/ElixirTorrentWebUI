# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir_torrent_web_ui,
  namespace: ElixirTorrentWebUI,
  generators: [timestamp_type: :utc_datetime]

# Where in-app bug reports are filed. Users are handed a browser URL that
# opens a pre-populated GitHub issue — nothing leaves the app until they
# review and click "Create".
config :elixir_torrent_web_ui, :issue_report,
  repo: "daniboybye/ElixirTorrentWebUI",
  labels: ["bug", "in-app-report"]

# Register the .torrent file extension so Phoenix LiveView's
# `allow_upload(..., accept: ~w(.torrent))` recognises it.
config :mime, :types, %{
  "application/x-bittorrent" => ["torrent"]
}

# Configure the endpoint
config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ElixirTorrentWebUIWeb.ErrorHTML, json: ElixirTorrentWebUIWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirTorrentWebUI.PubSub,
  live_view: [signing_salt: "vni4DRJ1"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.1",
  elixir_torrent_web_ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  elixir_torrent_web_ui: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
