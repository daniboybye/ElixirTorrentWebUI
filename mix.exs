defmodule ElixirTorrentWebUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_torrent_web_ui,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ElixirTorrentWebUI.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      elixir_torrent_dep(),
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Dual-mode dependency for the BitTorrent engine.
  #
  # By default we depend on the published Hex package (`elixir_torrent`).
  # During local development on both this UI and the engine, set
  # `ELIXIR_TORRENT_PATH` to a path on disk to override the source, e.g.
  #
  #     ELIXIR_TORRENT_PATH=../ElixirTorrent mix deps.get
  #     ELIXIR_TORRENT_PATH=../ElixirTorrent mix phx.server
  #
  # The Hex version is the canonical, committed version. The local override is
  # convenient for iterating on the engine without releasing a new package.
  defp elixir_torrent_dep do
    case System.get_env("ELIXIR_TORRENT_PATH") do
      nil -> {:elixir_torrent, "~> 0.1.1"}
      path -> {:elixir_torrent, path: path}
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind elixir_torrent_web_ui",
        "esbuild elixir_torrent_web_ui"
      ],
      "assets.deploy": [
        "tailwind elixir_torrent_web_ui --minify",
        "esbuild elixir_torrent_web_ui --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
