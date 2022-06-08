import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: '.mnesia/#{Mix.env}/#{node()}'

config :data_service,
  service_id: 1
