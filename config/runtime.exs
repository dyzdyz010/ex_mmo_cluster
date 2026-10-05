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
end

config :auth_server, AuthServerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("AUTH_PORT", "20000"))]

# ---------------------------------------------------------------------------
# Demo auto-login endpoint (POST /ingame/auto_login)
# ---------------------------------------------------------------------------
# Set DEV_AUTO_LOGIN=true in local/dev/demo deployments to let the Voxim client
# bootstrap a signed token by just sending a username.
dev_auto_login? = System.get_env("DEV_AUTO_LOGIN") in ["true", "1"]

config :auth_server, :dev_auto_login, dev_auto_login?
config :auth_server, :playtest_access_file, System.get_env("VOXIM_PLAYTEST_ACCESS_FILE")

# 全局系统功能：阿里云 DirectMail 使用对应地域 SMTP/465；仅本机邮件捕获器允许明文回环。
if mail_host = System.get_env("VOXIM_MAIL_HOST") do
  local_mail = mail_host in ["127.0.0.1", "localhost"]
  smtp = [
    relay: String.to_charlist(mail_host),
    from: System.fetch_env!("VOXIM_MAIL_FROM"),
    port: String.to_integer(System.get_env("VOXIM_MAIL_PORT",if(local_mail,do: "27025",else: "465"))),
    ssl: not local_mail, tls: :never, no_mx_lookups: true, retries: 0, timeout: 10_000,
    auth: if(local_mail,do: :never,else: :always)
  ]
  smtp = if local_mail do
    smtp
  else
    smtp ++ [username: String.to_charlist(System.fetch_env!("VOXIM_MAIL_USER")),
      password: String.to_charlist(System.fetch_env!("VOXIM_MAIL_PASSWORD")),
      sockopts: [verify: :verify_peer, cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(mail_host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]]
  end
  config :auth_server,:smtp,smtp
end

# Voxim R6 S4: 在线生成 baseline cache 与 overlay 日志根。非空时必须同时提供显式生成 manifest。
config :voxel_region, :root, System.get_env("VOXEL_REGION_ROOT")
config :voxel_region, :manifest_path, System.get_env("VOXEL_REGION_MANIFEST")
config :voxel_region, :projectile_backend, WorldServer.Movement.Projectile

# One explicitly deployed Voxim scene. Gate caches its World route at subscription/join;
# HTTP resolves this same route per request. Distributed deployments replace these refs.
config :world_server, :movement_routes, %{
  1 => %{
    scene_ref: {SceneServer.Movement.Scene, node()},
    world_ref: {VoxelRegion.World, node()},
    scene_epoch: 1
  }
}

config :gate_server, :voxel_scene_id, 1
config :auth_server, :voxel_scene_id, 1

# 入场身份：kernel_id 取发布的 kernel manifest 字节的 sha256（`VOXIM_KERNEL_MANIFEST`），profile_id 由主 Scene 配置的
# 移动 profile 与材料阻挡表导出；两者都可用十六进制环境变量显式覆盖（`VOXIM_KERNEL_ID` / `VOXIM_PROFILE_ID`）。
if cert = System.get_env("VOXIM_QUIC_CERT") do
  <<kernel_id::binary-size(32)>> =
    case System.get_env("VOXIM_KERNEL_ID") do
      nil -> :crypto.hash(:sha256, File.read!(System.fetch_env!("VOXIM_KERNEL_MANIFEST")))
      hex -> Base.decode16!(hex, case: :mixed)
    end

  <<profile_id::binary-size(32)>> =
    case System.get_env("VOXIM_PROFILE_ID") do
      nil ->
        System.fetch_env!("VOXIM_M1_CONFIG")
        |> SceneServer.Movement.Scene.load_config!()
        |> Map.fetch!(:profile)
        |> MmoContracts.Session.Codec.profile_id(
          MmoContracts.VoxelMaterialCatalog.blocking_hash()
        )

      hex ->
        Base.decode16!(hex, case: :mixed)
    end

  config :gate_server, :quic,
    name: GateServer.Transport.QuicListener,
    port: String.to_integer(System.fetch_env!("VOXIM_QUIC_PORT")),
    certfile: cert,
    keyfile: System.fetch_env!("VOXIM_QUIC_KEY"),
    hello:
      struct(MmoContracts.Session.Hello,
        protocol_version: MmoContracts.Session.Codec.protocol_version(),
        kernel_id: kernel_id,
        profile_id: profile_id
      )
end

# `VOXIM_M1_CONFIG` 是主 Scene（scene 1）的配置：Gate 的入场范围取自它。
# 单 Scene 部署由 scene_server 按它直接启动；设了 `VOXIM_TOPOLOGY` 时改由 `WorldServer.Topology` 按拓扑文件启动全部 Scene。
if config_path = System.get_env("VOXIM_M1_CONFIG") do
  config :gate_server, :quic, bounds: SceneServer.Movement.Scene.load_config!(config_path).bounds

  if topology = System.get_env("VOXIM_TOPOLOGY") do
    config :world_server, :topology, topology
  else
    config :scene_server, SceneServer.Movement.Scene,
      name: SceneServer.Movement.Scene,
      scene_id: 1,
      scene_epoch: 1,
      world_ref: {VoxelRegion.World, node()},
      config_path: config_path
  end
end

# 世界目录与资产（发布根里的文件）；未设时保持各自的代码默认值。
for {env, key} <- [
      {"VOXIM_PROPERTY_CATALOG_PATH", :property_catalog_path},
      {"VOXIM_THERMAL_ENVIRONMENT_PATH", :thermal_environment_path},
      {"VOXIM_MAGIC_CATALOG_PATH", :magic_catalog_path}
    ],
    value = System.get_env(env),
    value != nil,
    do: config(:voxel_region, key, value)

# 有限液体只在这个宏格盒内模拟（"x0,y0,z0,x1,y1,z1"）；不设即关闭液体。
if bounds = System.get_env("VOXIM_LIQUID_BOUNDS") do
  [x0, y0, z0, x1, y1, z1] =
    bounds |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))

  config :voxel_region, :liquid_bounds, {{x0, y0, z0}, {x1, y1, z1}}
end

if materials = System.get_env("VOXIM_PRODUCTION_MATERIALS") do
  config :voxel_region,
         :production_materials,
         materials
         |> String.split(",", trim: true)
         |> Enum.map(&String.to_integer(String.trim(&1)))
end

# 冷 miss 生成在每个请求进程里的并发上限；内存载荷缓存 L0–L3 的 LRU 字节上限（L4+ 常驻不计）。
config :voxel_region,
       :generation_concurrency,
       String.to_integer(System.get_env("VOXEL_REGION_GENERATION_CONCURRENCY", "8"))

config :voxel_region,
       :payload_cache_bytes,
       String.to_integer(System.get_env("VOXEL_REGION_PAYLOAD_CACHE_MB", "512")) * 1024 * 1024

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

  config :auth_server, AuthServerWeb.Endpoint,
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
end

config :voxel_region, :prefab_catalog_path, System.get_env("VOXIM_PREFAB_CATALOG_PATH")
