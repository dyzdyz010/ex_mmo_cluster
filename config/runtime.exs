import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

# ---------------------------------------------------------------------------
# Phoenix server toggle (applies to all envs when PHX_SERVER is set)
# ---------------------------------------------------------------------------

if System.get_env("PHX_SERVER") do
  config :auth_server, AuthServerWeb.Endpoint, server: true
  config :visualize_server, VisualizeServerWeb.Endpoint, server: true
end

config :auth_server, AuthServerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("AUTH_PORT", "20000"))]

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("VISUALIZE_PORT", "20001"))]

# ---------------------------------------------------------------------------
# Demo auto-login endpoint (POST /ingame/auto_login)
# ---------------------------------------------------------------------------
# Set DEV_AUTO_LOGIN=true in local/dev/demo deployments to let web and Bevy
# clients bootstrap a signed token by just sending a username.
dev_auto_login? = System.get_env("DEV_AUTO_LOGIN") in ["true", "1"]
world_pack_generate? = System.get_env("VOXEL_WORLD_PACK_GENERATE", "0") in ["true", "1"]

config :auth_server, :dev_auto_login, dev_auto_login?

dev_region_bootstrap_env = System.get_env("VOXEL_DEV_REGION_BOOTSTRAP")

dev_region_bootstrap? =
  case dev_region_bootstrap_env do
    nil -> dev_auto_login? and not world_pack_generate?
    value -> value in ["true", "1"]
  end

config :world_server, :default_voxel_region_bootstrap,
  enabled?: dev_region_bootstrap?,
  logical_scene_id: String.to_integer(System.get_env("VOXEL_DEV_REGION_LOGICAL_SCENE_ID", "1")),
  retry_ms: String.to_integer(System.get_env("VOXEL_DEV_REGION_RETRY_MS", "1000")),
  refresh_ms: String.to_integer(System.get_env("VOXEL_DEV_REGION_REFRESH_MS", "1800000")),
  seed_terrain?: System.get_env("VOXEL_DEV_REGION_SEED_TERRAIN", "1") != "0",
  rebuild_lod_projection?: System.get_env("VOXEL_DEV_REGION_REBUILD_LOD", "1") != "0"

world_pack_version = System.get_env("VOXEL_WORLD_PACK_VERSION", "worldgen-v1")
world_pack_status =
  System.get_env(
    "VOXEL_WORLD_PACK_STATUS",
    if(world_pack_generate?, do: "materializing", else: "missing")
  )

world_pack_content_version = System.get_env("VOXEL_WORLD_PACK_CONTENT_VERSION", world_pack_version)
world_pack_world_macro_extent = String.to_integer(System.get_env("VOXEL_WORLD_MACRO_EXTENT", "32768"))

world_pack_seed =
  case System.get_env("VOXEL_WORLD_SEED") do
    nil -> nil
    value -> String.to_integer(value)
  end

config :auth_server, :voxel_world_pack,
  status: world_pack_status,
  version: world_pack_version,
  content_version: world_pack_content_version,
  world_macro_extent: world_pack_world_macro_extent

config :world_server, :world_pack_bootstrapper,
  enabled?: world_pack_generate?,
  logical_scene_id: String.to_integer(System.get_env("VOXEL_WORLD_PACK_LOGICAL_SCENE_ID", "1")),
  chunk_min: System.get_env("VOXEL_WORLD_PACK_CHUNK_MIN", "-3,-3,-3"),
  chunk_max: System.get_env("VOXEL_WORLD_PACK_CHUNK_MAX", "3,3,3"),
  batch_size: String.to_integer(System.get_env("VOXEL_WORLD_PACK_BATCH_SIZE", "64")),
  max_chunks: System.get_env("VOXEL_WORLD_PACK_MAX_CHUNKS", "10000"),
  retry_ms: String.to_integer(System.get_env("VOXEL_WORLD_PACK_RETRY_MS", "1000")),
  version: world_pack_version,
  content_version: world_pack_content_version,
  world_macro_extent: world_pack_world_macro_extent,
  seed: world_pack_seed

# 旧运行时 WorldGen 已降级为 dev migration helper。正式 runtime 不应在缺 chunk /
# heightmap 时重跑噪声作为第二真值；需要时只能显式设置 VOXEL_WORLDGEN=1 做本地
# 开发临时材化，默认关闭。
config :scene_server, :voxel_worldgen,
  enabled?: System.get_env("VOXEL_WORLDGEN", "0") == "1",
  seed: String.to_integer(System.get_env("VOXEL_WORLD_SEED", "1337"))

# 阶段3 step3.2 chunk idle 驱逐:无订阅者 + 无活跃 field region 连续 idle 达 evict_after_ms 即自停,
# 让无界大世界的万级 chunk 进程内存有界(再访问由 DB 重载；WorldGen 仅可显式 dev opt-in)。test 关闭。
config :scene_server, :voxel_chunk_idle_eviction,
  enabled?: config_env() != :test and System.get_env("VOXEL_CHUNK_IDLE_EVICTION", "1") != "0",
  check_ms: String.to_integer(System.get_env("VOXEL_CHUNK_IDLE_CHECK_MS", "15000")),
  evict_after_ms: String.to_integer(System.get_env("VOXEL_CHUNK_IDLE_EVICT_AFTER_MS", "120000"))

# 阶段7-bis:peer 等待**轮询**(client 已改)的 give-up 超时。真集群下 peer 一出现即早返回,
# 此值只是单节点 give-up 上限;默认 250ms(原固定 sleep 1000ms),直接砍每个 interface 的启动
# 阻塞 → 砍冷启动。慢 gossip 的部署可 `BEACON_CLUSTER_JOIN_WAIT_MS` 调大。
config :beacon_server,
       :cluster_join_wait_ms,
       String.to_integer(System.get_env("BEACON_CLUSTER_JOIN_WAIT_MS", "250"))

# ---------------------------------------------------------------------------
# gate_server listen ports (env-driven so prod container can remap)
# ---------------------------------------------------------------------------

config :gate_server,
  tcp_port: String.to_integer(System.get_env("GATE_TCP_PORT", "20002")),
  udp_port: String.to_integer(System.get_env("GATE_UDP_PORT", "20003"))

if System.get_env("CLUSTER_MULTICAST_IF") do
  config :libcluster,
    topologies: [
      mmo_cluster: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: String.to_integer(System.get_env("CLUSTER_GOSSIP_PORT", "45892")),
          if_addr: System.get_env("CLUSTER_IF_ADDR", "0.0.0.0"),
          multicast_if: System.fetch_env!("CLUSTER_MULTICAST_IF"),
          multicast_addr: System.get_env("CLUSTER_MULTICAST_ADDR", "230.1.1.251"),
          multicast_ttl: String.to_integer(System.get_env("CLUSTER_MULTICAST_TTL", "1"))
        ]
      ]
    ]
end

# ---------------------------------------------------------------------------
# Production-only: secrets, DB, cluster disable
# ---------------------------------------------------------------------------

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :auth_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :visualize_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :auth_server, AuthServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :visualize_server, VisualizeServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  # --- Database (runtime-read; compile-time config.exs defaults are ignored)
  db_host =
    System.get_env("MMO_DB_HOST") ||
      raise "environment variable MMO_DB_HOST is missing"

  db_name =
    System.get_env("MMO_DB_NAME") ||
      raise "environment variable MMO_DB_NAME is missing"

  db_user =
    System.get_env("MMO_DB_USER") ||
      raise "environment variable MMO_DB_USER is missing"

  db_password =
    System.get_env("MMO_DB_PASSWORD") ||
      raise "environment variable MMO_DB_PASSWORD is missing"

  config :data_service, DataService.Repo,
    hostname: db_host,
    database: db_name,
    username: db_user,
    password: db_password,
    port: String.to_integer(System.get_env("MMO_DB_PORT", "5432")),
    pool_size: String.to_integer(System.get_env("MMO_DB_POOL_SIZE", "10"))

  # --- Cluster discovery
  #
  # Local/single-node mode can set DISABLE_CLUSTER=true to neutralize
  # libcluster gossip. Production Compose leaves this false so app and scalable
  # scene containers can discover each other inside the bridge network.
  if System.get_env("DISABLE_CLUSTER") in ["true", "1"] do
    config :libcluster, topologies: []
  end
end
