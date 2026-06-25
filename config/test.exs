import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :auth_server, AuthServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 20010],
  secret_key_base: "Mqe6YlSESPnhRs5c9BxstlH2R4ZvkNzflWyEYZITMIwyN74nYMpTF/5X02dyfmQN",
  server: false

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 20011],
  secret_key_base: "chLpul9HpLdUaDKG7mumliAFELOvmLdd5ELmYyAFFN2K8QRcHsOPe9JPS9Uiq//8",
  server: false

# Data Service — tests use a **separate** `mmo_test` database, NOT the dev DB.
# 这些测试不走 Ecto Sandbox,setup 里直接 `Repo.delete_all` / `WriteTokenStore.reset()`
# 等全表删除来隔离;若与活 dev 服务端共用 `mmo_dev`,跑测试就会**抹掉活服务端的体素
# 写令牌/区域目录**(实测一次:dev 在跑时跑 chunk_directory_test → 令牌全删 → 编辑全
# unknown_region_token)。故 test 默认指向 `mmo_test`,与 dev 物理隔离。CI/本地首次需
# `MMO_DB_NAME=mmo_test mix ecto.create/migrate -r DataService.Repo`(或下方脚本)。
config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_test"),
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

config :beacon_server, startup_banner_enabled: false

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
