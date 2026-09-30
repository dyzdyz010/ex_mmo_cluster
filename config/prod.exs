import Config

# 反向代理（nginx）终止 TLS；Auth 只提供 JSON / 二进制 API，没有静态资源。
config :auth_server, AuthServerWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
