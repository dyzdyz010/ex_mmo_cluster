import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

# Enable Phoenix servers when PHX_SERVER=true (release-friendly).
if System.get_env("PHX_SERVER") do
  config :auth_server, AuthServerWeb.Endpoint, server: true
  config :visualize_server, VisualizeServerWeb.Endpoint, server: true
end

config :auth_server, AuthServerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("AUTH_PORT", "4000"))]

config :visualize_server, VisualizeServerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("VISUALIZE_PORT", "4001"))]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :auth_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :visualize_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :auth_server, AuthServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :visualize_server, VisualizeServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
