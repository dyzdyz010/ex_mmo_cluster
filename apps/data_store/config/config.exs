import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: 'priv/.mnesia/#{Mix.env}/#{node()}'

import_config "#{Mix.env}.exs"
