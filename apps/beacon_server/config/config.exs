import Config

import_config "#{config_env()}.exs"

# libcluster topology configuration
# In production, replace with Cluster.Strategy.Kubernetes.DNS or similar
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
