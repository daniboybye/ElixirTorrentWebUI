import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/elixir_torrent_web_ui start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
desktop? = System.get_env("ELIXIR_TORRENT_DESKTOP") == "1"

if System.get_env("PHX_SERVER") do
  config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

http_ip =
  if desktop? do
    {127, 0, 0, 1}
  else
    {0, 0, 0, 0, 0, 0, 0, 0}
  end

config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint, http: [ip: http_ip, port: port]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if desktop? do
        "Ymqn13aj7ehGUKNVd2oEc8ye6wpWM8fXpGT8FF2WCJiwCvIyaKekPwci/GKe7W4a"
      else
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
      end

  host = System.get_env("PHX_HOST") || if(desktop?, do: "127.0.0.1", else: "example.com")
  scheme = if desktop?, do: "http", else: "https"
  url_port = if desktop?, do: port, else: 443

  config :elixir_torrent_web_ui, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  endpoint =
    [
      url: [host: host, port: url_port, scheme: scheme],
      secret_key_base: secret_key_base
    ]
    |> then(fn opts ->
      if desktop? do
        Keyword.put(opts, :check_origin, false)
      else
        opts
      end
    end)

  config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint, endpoint

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :elixir_torrent_web_ui, ElixirTorrentWebUIWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
