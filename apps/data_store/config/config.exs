import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: 'priv/.mnesia/#{Mix.env}/#{node()}'

config :data_store,
  store_role: :master

import_config "#{Mix.env}.exs"
