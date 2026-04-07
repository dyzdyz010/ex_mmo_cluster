defmodule BeaconServer.Client do
  @moduledoc """
  Client module for interacting with the BeaconServer.

  Provides a stable API for service registration and discovery.
  Tries Horde distributed registry first, falls back to hardcoded
  beacon node during migration.

  After migration is complete (Step 3.6), the fallback is removed.
  """

  require Logger

  @fallback_beacon :"beacon1@127.0.0.1"

  @doc """
  Connect to the cluster and join the beacon.
  Uses libcluster for auto-discovery. Falls back to manual Node.connect.
  """
  @spec join_cluster() :: :ok | :error
  def join_cluster do
    # libcluster handles this automatically via Cluster.Supervisor.
    # Manual fallback for nodes not yet running libcluster.
    case Node.list() do
      [] ->
        Logger.info("No cluster peers found via libcluster, trying fallback beacon...")

        if Node.connect(@fallback_beacon) do
          Logger.info("Connected to fallback beacon #{@fallback_beacon}")
          :ok
        else
          Logger.warning("Could not connect to fallback beacon #{@fallback_beacon}")
          :error
        end

      nodes ->
        Logger.info("Cluster peers found: #{inspect(nodes)}")
        :ok
    end
  end

  @doc """
  Register this node's resource and requirements with the beacon.
  """
  @spec register(node(), module(), atom(), [atom()]) :: :ok | {:error, term()}
  def register(node, module, resource, requirement) do
    credentials = {node, module, resource, requirement}

    case call_beacon({:register, credentials}) do
      :ok ->
        Logger.info("Registered #{resource} with beacon")
        :ok

      error ->
        Logger.error("Failed to register with beacon: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Get requirements for the given node from the beacon.
  """
  @spec get_requirements(node()) :: {:ok, list()} | {:err, nil}
  def get_requirements(node) do
    call_beacon({:get_requirements, node})
  end

  # Try to find BeaconServer.Beacon via Horde registry first,
  # then fall back to hardcoded node.
  defp call_beacon(message) do
    case find_beacon() do
      {:ok, pid} ->
        GenServer.call(pid, message)

      :error ->
        Logger.warning("Beacon not found via Horde, trying fallback #{@fallback_beacon}")
        GenServer.call({BeaconServer.Beacon, @fallback_beacon}, message)
    end
  end

  defp find_beacon do
    # Try Horde distributed registry
    case Horde.Registry.lookup(BeaconServer.DistributedRegistry, :beacon) do
      [{pid, _}] -> {:ok, pid}
      _ -> find_beacon_local()
    end
  end

  defp find_beacon_local do
    # Try local named process
    case Process.whereis(BeaconServer.Beacon) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end
end
