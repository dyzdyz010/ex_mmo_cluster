# Start the Endpoint and its dependencies for --no-start mode.
# Phoenix web and LiveView tests need the Endpoint's ETS config table.
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:phoenix)
{:ok, _} = VisualizeServerWeb.Telemetry.start_link([])
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: VisualizeServer.PubSub)
{:ok, _} = VisualizeServerWeb.Endpoint.start_link()

ExUnit.start()
