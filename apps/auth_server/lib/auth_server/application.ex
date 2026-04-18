defmodule AuthServer.Application do
  @moduledoc """
  Boots the auth service runtime.

  In addition to the Phoenix endpoint, this application optionally starts the
  cluster-facing auth interface outside tests so gate/runtime flows can discover
  the auth service and validate tokens against it.
  """

  use Application

  # Capture the build-time env so the release (where `Mix` is not loaded) can
  # still answer "are we in :test?" — this becomes a literal `false` in prod.
  @is_test_build Mix.env() == :test

  @impl true
  def start(_type, _args) do
    children =
      [
        AuthServerWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:auth_server, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AuthServer.PubSub},
        AuthServerWeb.Endpoint
      ] ++ interface_children()

    opts = [strategy: :one_for_one, name: AuthServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp interface_children do
    if Application.get_env(:auth_server, :start_interface?, not @is_test_build) do
      [{AuthServer.InterfaceSup, name: AuthServer.InterfaceSup}]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    AuthServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
