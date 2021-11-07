import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: '.mnesia/#{Mix.env}/#{node()}'
