import Config

import_config("../../../config/config.exs")

config :mnesia,
  dir: :code.priv_dir(:data_store) ++ '/.mnesia/#{Mix.env}/#{node()}'

import_config "#{Mix.env}.exs"
