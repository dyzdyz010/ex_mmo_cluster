import Config

import_config("../../../config/config.exs")

db_port = String.to_integer(System.get_env("MMO_DB_PORT", "5432"))
db_pool_size = String.to_integer(System.get_env("MMO_DB_POOL_SIZE", "10"))

config :mnesia,
  dir: ~c"priv/.mnesia/#{Mix.env()}/#{node()}"

config :data_service,
  service_id: 1,
  use_ecto: true,
  ecto_repos: [DataService.Repo]

config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_dev"),
  username: System.get_env("MMO_DB_USER", "postgres"),
  password: System.get_env("MMO_DB_PASSWORD", "postgres"),
  hostname: System.get_env("MMO_DB_HOST", "localhost"),
  port: db_port,
  pool_size: db_pool_size
