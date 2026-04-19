import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :auth_server, AuthServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Mqe6YlSESPnhRs5c9BxstlH2R4ZvkNzflWyEYZITMIwyN74nYMpTF/5X02dyfmQN",
  server: false

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "chLpul9HpLdUaDKG7mumliAFELOvmLdd5ELmYyAFFN2K8QRcHsOPe9JPS9Uiq//8",
  server: false

# Data Service — test uses the configured Postgres instance
config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_dev"),
  username: System.get_env("MMO_DB_USER", "postgres"),
  password: System.get_env("MMO_DB_PASSWORD", "postgres"),
  hostname: System.get_env("MMO_DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("MMO_DB_PORT", "5432")),
  pool_size: 5

# Umbrella tests run in a single local node on Windows and can leave libcluster's
# fixed gossip socket bound between rapid reruns. Auth/DataService tests do not
# need distributed discovery, so disable the topology in test to avoid flaky
# startup failures before ExUnit boots.
config :libcluster, topologies: []

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
