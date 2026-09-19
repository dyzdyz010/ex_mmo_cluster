import Config

import_config("../../../config/config.exs")


config :mnesia,
  dir: ~c"priv/.mnesia/#{Mix.env()}/#{node()}"

config :data_service,
  service_id: 1,
  use_ecto: true,
  ecto_repos: [DataService.Repo]

# Repo 配置只由根 config/config.exs 与对应环境文件定义；不能覆盖测试独占库。
