defmodule AuthServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Boots the auth service runtime.

  In addition to the Phoenix endpoint, this application optionally starts the
  cluster-facing auth interface outside tests so gate/runtime flows can discover
  the auth service and validate tokens against it.

  See `apps/auth_server/lib/auth_server/README.md` for the local subtree layout.
  """

  use Application

  @impl true
  @doc "Starts the auth application supervision tree."
  def start(_type, _args) do
    children =
      [
        # Start the Telemetry supervisor
        AuthServerWeb.Telemetry,
        # Start the PubSub system
        {Phoenix.PubSub, name: AuthServer.PubSub},
        # Start the Endpoint (http/https)
        AuthServerWeb.Endpoint
        # Start the cluster-facing auth interface outside tests so gate/auth
        # discovery works in real runtime flows without hanging local tests.
      ] ++ interface_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AuthServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp interface_children do
    if Mix.env() == :test do
      []
    else
      [{AuthServer.InterfaceSup, name: AuthServer.InterfaceSup}]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AuthServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
