import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :auth_server, AuthServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "x2j8fVNYUpjhnt59L9KZuZyuEriApRKcMghPUkEiEZb+DGwsibCEa/GOMtMyd0+F",
  server: false

# In test we don't send emails.
config :auth_server, AuthServer.Mailer, adapter: Swoosh.Adapters.Test

# DataService.Repo config for auth_worker tests that need PostgreSQL.
# Required when running `mix test --no-start` from apps/auth_server/ because
# the local config_path does not include the umbrella root config.
config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_dev"),
  username: System.get_env("MMO_DB_USER", "mmo_dev"),
  password: System.get_env("MMO_DB_PASSWORD", "mmo_dev"),
  hostname: System.get_env("MMO_DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("MMO_DB_PORT", "5432")),
  pool_size: 5

config :data_service, ecto_repos: [DataService.Repo]

# Disable libcluster in test to avoid :eaddrinuse on Windows
config :libcluster, topologies: []

# Print only warnings and errors during test
config :logger, level: :warn

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
