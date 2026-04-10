import Config

config :auth_server, AuthServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  url: [host: "localhost"],
  render_errors: [view: AuthServerWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: AuthServer.PubSub,
  secret_key_base: "x2j8fVNYUpjhnt59L9KZuZyuEriApRKcMghPUkEiEZb+DGwsibCEa/GOMtMyd0+F",
  live_view: [signing_salt: "VRqBPZwk"],
  server: false

config :auth_server, AuthServer.Mailer, adapter: Swoosh.Adapters.Test

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  url: [host: "localhost"],
  render_errors: [view: VisualizeServerWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: VisualizeServer.PubSub,
  secret_key_base: "e9Sovnin9dxiZGj9+CW6piAVDtdZvwrIXj7xyB3b8NKDdrQID/5bZChtbAPK+noe",
  live_view: [signing_salt: "uSUohzqu"],
  server: false

config :visualize_server, VisualizeServer.Mailer, adapter: Swoosh.Adapters.Test

config :data_service, DataService.Repo,
  database: System.get_env("MMO_DB_NAME", "mmo_dev"),
  username: System.get_env("MMO_DB_USER", "mmo_dev"),
  password: System.get_env("MMO_DB_PASSWORD", "mmo_dev"),
  hostname: System.get_env("MMO_DB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("MMO_DB_PORT", "5432")),
  pool_size: 5

config :logger, level: :warn
config :phoenix, :plug_init_mode, :runtime
