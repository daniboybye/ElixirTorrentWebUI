defmodule ElixirTorrentWebUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_torrent_web_ui,
      version: "0.2.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
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
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp elixirc_options do
    [warnings_as_errors: true]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      elixir_torrent_dep(),
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:sobelow, "~> 0.14", only: :dev, runtime: false},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
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

  # Use the published package by default. Set ELIXIR_TORRENT_PATH only while
  # developing and validating against a local engine checkout, e.g.
  #
  #     ELIXIR_TORRENT_PATH=../ElixirTorrent mix deps.get
  #     ELIXIR_TORRENT_PATH=../ElixirTorrent mix phx.server
  defp elixir_torrent_dep do
    case System.get_env("ELIXIR_TORRENT_PATH") do
      nil -> {:elixir_torrent, "~> 0.3.0"}
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
      setup: ["deps.get", "assets.setup", "assets.build", "mac.icon"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind elixir_torrent_web_ui",
        "esbuild elixir_torrent_web_ui"
      ],
      "assets.deploy": [
        "compile",
        "tailwind elixir_torrent_web_ui --minify",
        "esbuild elixir_torrent_web_ui --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test --warnings-as-errors"
      ],
      quality: [
        "compile --warnings-as-errors",
        "dialyzer",
        "credo --all",
        "sobelow --skip --strict --private --exit --threshold medium"
      ],
      "mac.icon": ["cmd python3 priv/scripts/macos/generate-app-icon.py"],
      "mac.dmg": ["cmd priv/scripts/macos/build-macos-dmg.sh"]
    ]
  end
end
