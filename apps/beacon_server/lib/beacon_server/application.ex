defmodule BeaconServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # Cluster auto-discovery
      {Cluster.Supervisor, [topologies, [name: BeaconServer.ClusterSupervisor]]},
      # Distributed registry — processes registered here are visible cluster-wide
      {Horde.Registry, [name: BeaconServer.DistributedRegistry, keys: :unique, members: :auto]},
      # Distributed supervisor — can start processes on any node
      {Horde.DynamicSupervisor, [name: BeaconServer.DistributedSupervisor, strategy: :one_for_one, members: :auto]},
      # The beacon GenServer (registered in Horde for HA)
      {BeaconServer.Beacon, name: BeaconServer.Beacon}
    ]

    opts = [strategy: :one_for_one, name: BeaconServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
