import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: ~c"priv/.mnesia/#{Mix.env}/#{node()}"

config :data_service,
  service_id: 1,
  use_ecto: true,
  ecto_repos: [DataService.Repo]

config :data_service, DataService.Repo,
  database: "mmo_dev",
  username: "mmo_dev",
  password: "mmo_dev",
  hostname: "localhost",
  pool_size: 10
