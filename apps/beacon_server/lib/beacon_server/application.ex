defmodule BeaconServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      []
      |> maybe_add_cluster_supervisor(topologies)
      |> maybe_add_registry()

    opts = [strategy: :one_for_one, name: BeaconServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_cluster_supervisor(children, []), do: children

  defp maybe_add_cluster_supervisor(children, topologies) do
    children ++ [{Cluster.Supervisor, [topologies, [name: BeaconServer.ClusterSupervisor]]}]
  end

  defp maybe_add_registry(children) do
    children ++
      [{Horde.Registry, [name: BeaconServer.DistributedRegistry, keys: :unique, members: :auto]}]
  end
end
