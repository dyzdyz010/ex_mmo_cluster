import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: '#{:code.priv_dir(:data_store)}/.mnesia/#{Mix.env}/#{node()}'

config :data_service,
  service_id: 1
