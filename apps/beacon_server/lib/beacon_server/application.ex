defmodule BeaconServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # Cluster auto-discovery (libcluster)
      {Cluster.Supervisor, [topologies, [name: BeaconServer.ClusterSupervisor]]},
      # Distributed registry for service discovery (replaces BeaconServer.Beacon)
      {Horde.Registry, [name: BeaconServer.DistributedRegistry, keys: :unique, members: :auto]},
    ]

    opts = [strategy: :one_for_one, name: BeaconServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
