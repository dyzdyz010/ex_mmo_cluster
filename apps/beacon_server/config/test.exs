import Config

# Tests do not need libcluster gossip; disabling the topology keeps the
# umbrella suite isolated from UDP port contention (`:eaddrinuse`).
config :libcluster, topologies: []
