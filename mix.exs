defmodule BabelSync.MixProject do
  use Mix.Project

  def project do
    [
      app: :babel_sync,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [plt_local_path: "priv/plts", plt_add_apps: [:mix, :ex_unit]],
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
      mod: {BabelSync.Application, []},
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
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:ecto_sqlite3, "~> 0.26"},
      {:y_ex, "~> 0.13"},
      {:mdex, "~> 0.9"},
      {:anubis_mcp, "~> 2.2"},
      {:oidcc, "~> 3.9"},
      {:wax_, "~> 0.7"},
      {:gen_smtp, "~> 1.3"},
      {:rustler, ">= 0.0.0", optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:deps_nix, "~> 3.2", only: :dev, runtime: false},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.12"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  @js "assets/js js/core plugin/src plugin/test plugin/esbuild.config.mjs test/e2e"

  defp aliases do
    [
      setup: ["deps.get", "cmd npm install", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind babel_sync", "esbuild babel_sync", "plugin.build"],
      "assets.deploy": [
        "tailwind babel_sync --minify",
        "esbuild babel_sync --minify",
        "plugin.build",
        "phx.digest"
      ],
      "plugin.build": [
        "cmd --cd plugin node esbuild.config.mjs production",
        "cmd mkdir -p priv/plugin",
        "cmd cp plugin/main.js plugin/manifest.json priv/plugin/"
      ],
      "js.check": [
        "cmd oxfmt #{@js}",
        "cmd oxlint --deny-warnings #{@js}",
        "cmd --cd plugin npx tsc --noEmit"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "js.check",
        "test"
      ]
    ]
  end
end
