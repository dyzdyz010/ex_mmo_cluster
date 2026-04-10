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

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
config :phoenix, :json_library, Jason

# AuthServer endpoint base config for umbrella-root compile/test runs.
config :auth_server, AuthServerWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: AuthServerWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: AuthServer.PubSub,
  live_view: [signing_salt: "VRqBPZwk"]

# VisualizeServer endpoint base config for umbrella-root compile/test runs.
config :visualize_server, VisualizeServerWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: VisualizeServerWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: VisualizeServer.PubSub,
  live_view: [signing_salt: "uSUohzqu"]

# Cluster auto-discovery (all nodes)
config :libcluster,
  topologies: [
    mmo_cluster: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_if: "127.0.0.1",
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1
      ]
    ]
  ]

# Data Service - Ecto configuration
config :data_service,
  ecto_repos: [DataService.Repo]

config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_dev"),
  username: System.get_env("MMO_DB_USER", "mmo_dev"),
  password: System.get_env("MMO_DB_PASSWORD", "mmo_dev"),
  hostname: System.get_env("MMO_DB_HOST", "localhost"),
  port: db_port,
  pool_size: db_pool_size

# Import environment specific config. This must remain at the bottom
# so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
