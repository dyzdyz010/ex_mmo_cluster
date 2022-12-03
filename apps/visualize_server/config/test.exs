import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e9Sovnin9dxiZGj9+CW6piAVDtdZvwrIXj7xyB3b8NKDdrQID/5bZChtbAPK+noe",
  server: false

# In test we don't send emails.
config :visualize_server, VisualizeServer.Mailer,
  adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warn

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
