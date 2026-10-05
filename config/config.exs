# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

db_port = String.to_integer(System.get_env("MMO_DB_PORT", "5432"))
db_pool_size = String.to_integer(System.get_env("MMO_DB_POOL_SIZE", "10"))

# ===========================================================================
# AuthServer (Phoenix 1.8)
# ===========================================================================

config :auth_server,
  generators: [timestamp_type: :utc_datetime]

config :auth_server, AuthServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AuthServerWeb.ErrorHTML, json: AuthServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AuthServer.PubSub,
  live_view: [signing_salt: "uYwimls9"]

# ===========================================================================
# Asset pipelines (esbuild + tailwind) for all Phoenix apps
# ===========================================================================

config :esbuild,
  version: "0.25.4",
  auth_server: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/auth_server/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  auth_server: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/auth_server", __DIR__)
  ]

# ===========================================================================
# Shared Phoenix / Logger
# ===========================================================================

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "password_confirmation", "code", "invite", "token", "refresh_token", "access_token", "email"]

# Silence Phoenix LiveView colocated-hook symlink warning on Windows.
config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

# ===========================================================================
# Data Service (Ecto + PostgreSQL)
# ===========================================================================

config :data_service,
  ecto_repos: [DataService.Repo]

config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_dev"),
  username: System.get_env("MMO_DB_USER", "postgres"),
  password: System.get_env("MMO_DB_PASSWORD", "postgres"),
  hostname: System.get_env("MMO_DB_HOST", "localhost"),
  port: db_port,
  pool_size: db_pool_size

# Import environment specific config. This must remain at the bottom
# so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
