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

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
config :phoenix, :json_library, Jason

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
  database: "mmo_dev",
  username: "mmo_dev",
  password: "mmo_dev",
  hostname: "localhost",
  pool_size: 10
