import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: 'priv/.mnesia/#{Mix.env}/#{node()}'

config :data_service,
  service_id: 1
