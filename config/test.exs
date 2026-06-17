import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3t9gxZCPfiB6H5pbAfhfLibT7La1yoO3b1/4/2au5IJWd40Kcmx49rrfIfE6KOVi",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :elixir_torrent_web_ui,
  data_dir: Path.expand("tmp/elixir_torrent_web_ui_test"),
  use_data_cwd: false

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
