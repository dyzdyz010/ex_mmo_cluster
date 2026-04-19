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
  http: [port: String.to_integer(System.get_env("AUTH_PORT", "4000"))]

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("VISUALIZE_PORT", "4001"))]

# ---------------------------------------------------------------------------
# Dev-only auto-login endpoint (POST /ingame/auto_login)
# ---------------------------------------------------------------------------
# Set DEV_AUTO_LOGIN=true in local dev/staging to let the bevy_client bootstrap
# a signed token by just sending a username. MUST stay unset in production —
# the prod guard below raises at boot if someone forgets.
dev_auto_login? = System.get_env("DEV_AUTO_LOGIN") in ["true", "1"]

config :auth_server, :dev_auto_login, dev_auto_login?

if config_env() == :prod and dev_auto_login? do
  raise """
  DEV_AUTO_LOGIN=true is set in a production release. This flag exposes an
  unauthenticated endpoint that upserts accounts from a bare username and
  must never be enabled in prod. Remove the variable from the prod
  environment before starting the release.
  """
end

# ---------------------------------------------------------------------------
# gate_server listen ports (env-driven so prod container can remap)
# ---------------------------------------------------------------------------

config :gate_server,
  tcp_port: String.to_integer(System.get_env("GATE_TCP_PORT", "29000")),
  udp_port: String.to_integer(System.get_env("GATE_UDP_PORT", "29001"))

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
  # MVP single-container mode sets DISABLE_CLUSTER=true to neutralize
  # libcluster gossip (no UDP multicast between containers). Each cluster
  # component still works locally via :pg / Horde in single-node mode.
  if System.get_env("DISABLE_CLUSTER") in ["true", "1"] do
    config :libcluster, topologies: []
  end
end
