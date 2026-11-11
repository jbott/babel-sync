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
#     PHX_SERVER=true bin/babel_sync start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
mode =
  case System.get_env("BABELSYNC_MODE", "single") do
    "single" -> :single
    "multi" -> :multi
    other -> raise "BABELSYNC_MODE must be single or multi, got: #{inspect(other)}"
  end

storage =
  case System.get_env("BABELSYNC_STORAGE", if(mode == :single, do: "local", else: "remote")) do
    "local" -> :local
    "remote" -> :remote
    other -> raise "BABELSYNC_STORAGE must be local or remote, got: #{inspect(other)}"
  end

repo = if storage == :local, do: BabelSync.Repo.SQLite, else: BabelSync.Repo.Postgres

data_dir =
  System.get_env("BABELSYNC_DATA_DIR") ||
    case config_env() do
      :prod -> raise "environment variable BABELSYNC_DATA_DIR is missing"
      :dev -> Path.expand("../.dev/data", __DIR__)
      :test -> Path.expand("../tmp/test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)
    end

auth =
  System.get_env("BABELSYNC_AUTH", if(mode == :single, do: "none", else: "oidc"))
  |> String.split(",", trim: true)
  |> Enum.map(fn
    "none" ->
      :none

    "passkey" ->
      :passkey

    "oidc" ->
      :oidc

    "magic_link" ->
      :magic_link

    other ->
      raise "BABELSYNC_AUTH lists none, passkey, oidc or magic_link, got: #{inspect(other)}"
  end)
  |> case do
    [:none] when mode == :single -> []
    [:none] -> raise "BABELSYNC_AUTH=none is only allowed with BABELSYNC_MODE=single"
    methods -> methods
  end

if :none in auth, do: raise("BABELSYNC_AUTH=none cannot be combined with other methods")

if mode == :multi and :oidc not in auth and :magic_link not in auth do
  raise "BABELSYNC_MODE=multi needs oidc or magic_link in BABELSYNC_AUTH so people can sign in the first time"
end

csv = fn name ->
  name |> System.get_env("") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

oidc_require =
  for pair <- csv.("BABELSYNC_OIDC_REQUIRE") do
    case String.split(pair, "=", parts: 2) do
      [claim, value] -> {claim, value}
      _other -> raise "BABELSYNC_OIDC_REQUIRE is a list of claim=value, got: #{inspect(pair)}"
    end
  end

if :oidc in auth do
  for name <- ~w(BABELSYNC_OIDC_ISSUER BABELSYNC_OIDC_CLIENT_ID), is_nil(System.get_env(name)) do
    raise "environment variable #{name} is missing"
  end

  if mode == :single and oidc_require == [] do
    raise "BABELSYNC_OIDC_REQUIRE must name the owner, for example email=you@example.com, " <>
            "or anyone with an account at the provider could sign in"
  end
end

config :babel_sync, BabelSync.Auth.OIDC,
  issuer: System.get_env("BABELSYNC_OIDC_ISSUER"),
  client_id: System.get_env("BABELSYNC_OIDC_CLIENT_ID"),
  client_secret: System.get_env("BABELSYNC_OIDC_CLIENT_SECRET"),
  label: System.get_env("BABELSYNC_OIDC_LABEL", "single sign-on"),
  scopes: String.split(System.get_env("BABELSYNC_OIDC_SCOPES", "openid email profile")),
  require: oidc_require

config :babel_sync, BabelSync.Auth.MagicLink,
  from: System.get_env("BABELSYNC_MAIL_FROM", "babelsync@localhost"),
  allowed_emails: Enum.map(csv.("BABELSYNC_ALLOWED_EMAILS"), &String.downcase/1)

if smtp_host = System.get_env("BABELSYNC_SMTP_HOST") do
  config :babel_sync, BabelSync.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_host,
    port: String.to_integer(System.get_env("BABELSYNC_SMTP_PORT", "587")),
    username: System.get_env("BABELSYNC_SMTP_USERNAME"),
    password: System.get_env("BABELSYNC_SMTP_PASSWORD"),
    tls: :always,
    auth: if(System.get_env("BABELSYNC_SMTP_USERNAME"), do: :always, else: :never)
else
  if :magic_link in auth and config_env() == :prod do
    raise "magic_link sign-in needs BABELSYNC_SMTP_HOST to send mail"
  end
end

if storage == :local, do: File.mkdir_p!(data_dir)

config :babel_sync,
  mode: mode,
  auth: auth,
  storage: storage,
  repo: repo,
  data_dir: data_dir,
  ecto_repos: [repo]

config :babel_sync, BabelSync.Repo.SQLite,
  database: Path.join(data_dir, "babel_sync.db"),
  priv: "priv/repo",
  journal_mode: :wal,
  busy_timeout: 5_000,
  foreign_keys: :on

config :babel_sync, BabelSync.Repo.Postgres, priv: "priv/repo"

if storage == :remote do
  s3_env = fn name, dev_default ->
    System.get_env(name) ||
      if config_env() == :prod,
        do: raise("environment variable #{name} is missing"),
        else: dev_default
  end

  config :babel_sync, BabelSync.Blobs.Store.S3,
    endpoint: s3_env.("BABELSYNC_S3_ENDPOINT", "http://127.0.0.1:7070"),
    bucket: s3_env.("BABELSYNC_S3_BUCKET", "babelsync-#{config_env()}"),
    region: s3_env.("BABELSYNC_S3_REGION", "us-east-1"),
    access_key_id: s3_env.("BABELSYNC_S3_ACCESS_KEY_ID", "babel_sync"),
    secret_access_key: s3_env.("BABELSYNC_S3_SECRET_ACCESS_KEY", "babelsyncsecret")
end

if max_blob = System.get_env("BABELSYNC_MAX_BLOB_BYTES") do
  config :babel_sync, BabelSync.Blobs, max_size: String.to_integer(max_blob)
end

if System.get_env("PHX_SERVER") do
  config :babel_sync, BabelSyncWeb.Endpoint, server: true
end

config :babel_sync, BabelSyncWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :babel_sync, BabelSyncWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/babel_sync_web/router\.ex$"E,
        ~r"lib/babel_sync_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  if storage == :remote do
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :babel_sync, BabelSync.Repo.Postgres,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :babel_sync, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :babel_sync, BabelSyncWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :babel_sync, BabelSyncWeb.Endpoint,
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
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :babel_sync, BabelSyncWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :babel_sync, BabelSync.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
