# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rustler_precompiled, :force_build, y_ex: true
config :elixir_make, :force_build, exqlite: System.get_env("EXQLITE_FORCE_BUILD") == "1"

default_storage =
  if System.get_env("BABELSYNC_MODE", "single") == "single", do: "local", else: "remote"

mix_task_repo =
  if System.get_env("BABELSYNC_STORAGE", default_storage) == "local",
    do: BabelSync.Repo.SQLite,
    else: BabelSync.Repo.Postgres

config :babel_sync,
  ecto_repos: [mix_task_repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :babel_sync, BabelSync.Sync,
  idle_timeout: :timer.minutes(5),
  keep_up_every: :timer.seconds(10),
  settle_after: :timer.seconds(30),
  settle_within: :timer.minutes(5),
  compact_after: 200

config :anubis_mcp, :session_store, enabled: true, adapter: BabelSync.MCP.SessionStore

config :babel_sync, BabelSync.Janitor,
  enabled: true,
  retention_days: 30,
  versions_per_note: 1000,
  interval: :timer.hours(1)

config :babel_sync, BabelSync.Sources,
  enabled: true,
  schedule: true,
  tick: :timer.seconds(30),
  deadline: :timer.minutes(3),
  requests: 50,
  writes: 2_000,
  response_bytes: 5_000_000,
  log_bytes: 100_000,
  state_bytes: 100_000,
  private_hosts: []

config :babel_sync, BabelSync.OAuth,
  unapproved_clients: 1000,
  registrations_per_hour: 30,
  idle_grant_days: 180

config :babel_sync, :rate_limits,
  sign_in: {30, 60},
  sign_in_link: {10, 3600},
  token: {120, 60}

config :babel_sync, BabelSync.Blobs, max_size: 5 * 1024 * 1024 * 1024, vault_quota: nil

# Configure the endpoint
config :babel_sync, BabelSyncWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BabelSyncWeb.ErrorHTML, json: BabelSyncWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BabelSync.PubSub,
  live_view: [signing_salt: "Y/zyoE8T"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :babel_sync, BabelSync.Mailer, adapter: Swoosh.Adapters.Local

config :mdex_native, syntax_highlighter: :syntect

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  path: System.get_env("MIX_ESBUILD_PATH"),
  babel_sync: [
    args:
      ~w(js/app.js --bundle --format=esm --splitting --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  maplibre_worker: [
    args:
      ~w(../node_modules/maplibre-gl/dist/maplibre-gl-worker.mjs --outfile=../priv/static/assets/js/maplibre-worker.js),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  path: System.get_env("MIX_TAILWIND_PATH"),
  babel_sync: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
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
