defmodule AuthServer.Application do
  @moduledoc """
  Boots the auth service runtime (Phoenix endpoint for the Voxim HTTP routes).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        AuthServerWeb.Telemetry,
        AuthServer.RateLimit,
        AuthServer.Connections,
        {Phoenix.PubSub, name: AuthServer.PubSub},
        AuthServerWeb.Endpoint
      ]

    opts = [strategy: :one_for_one, name: AuthServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AuthServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
