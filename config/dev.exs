import Config

# For development, we disable any cache and enable
# debugging and code reloading.

config :auth_server, AuthServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "0RfF0SEZuj/kdiHTSqtQ3bMFQucfbZXWn4AG1XWy7Hd4rKL9C9fOXdhR8iFiMuED",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:auth_server, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:auth_server, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/auth_server_web/router\.ex$"E,
      ~r"lib/auth_server_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :auth_server, dev_routes: true

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "cRHn0OH9C34RWALtOr+NCizxbJwJ4oEvmxzGuK8t1sC2MO9OVtTUb598BHSsID3l",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:visualize_server, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:visualize_server, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/visualize_server_web/router\.ex$"E,
      ~r"lib/visualize_server_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :visualize_server, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
