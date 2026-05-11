defmodule BeaconServer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    BeaconServer.StartupBanner.print_once()

    topologies = cluster_topologies()

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

  defp cluster_topologies do
    if cluster_disabled?() do
      []
    else
      Application.get_env(:libcluster, :topologies, [])
    end
  end

  defp cluster_disabled? do
    Application.get_env(:beacon_server, :disable_cluster, false) ||
      System.get_env("DISABLE_CLUSTER") in ["true", "1"] ||
      mix_test_env?()
  end

  defp mix_test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
