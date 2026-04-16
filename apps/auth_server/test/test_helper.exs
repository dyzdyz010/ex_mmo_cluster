# Start the Endpoint and its dependencies for --no-start mode.
# Phoenix web tests and token tests need the Endpoint's ETS config table.
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:phoenix)
{:ok, _} = AuthServerWeb.Telemetry.start_link([])
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: AuthServer.PubSub)
{:ok, _} = AuthServerWeb.Endpoint.start_link()

ExUnit.start()
