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

# 只测试：每个 VM 独占数据库，清表不会影响另一测试进程或开发服务。
# 跨进程迁移/分布式测试通过 MMO_TEST_DB_NAME 显式传递同一测试库名并负责清理。
# MMO_DB_NAME 只用于开发/运行环境，不作为测试库入口。
config :data_service, DataService.Repo,
  database:
    System.get_env(
      "MMO_TEST_DB_NAME",
      "mmo_test_#{System.pid()}_#{System.system_time(:microsecond)}"
    ),
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

# Most scene unit tests build isolated chunks without a launcher/world-pack
# materialization step. Keep that fixture path explicit so production runtime
# can default to failing on missing authoritative chunk snapshots.
config :scene_server, :voxel_missing_chunk_policy, :empty

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
