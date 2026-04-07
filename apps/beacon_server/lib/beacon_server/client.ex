defmodule BeaconServer.Client do
  @moduledoc """
  Client module for interacting with the BeaconServer.

  Provides a stable API for service registration and discovery.
  Uses Horde distributed registry for beacon lookup, with local
  process fallback. libcluster handles node discovery automatically.
  """

  require Logger

  @doc """
  Connect to the cluster.
  libcluster handles auto-discovery via Cluster.Supervisor.
  This function waits briefly for peers to appear.
  """
  @spec join_cluster() :: :ok | :error
  def join_cluster do
    case Node.list() do
      [] ->
        # Give libcluster a moment to discover peers
        Process.sleep(1000)

        case Node.list() do
          [] ->
            Logger.warning("No cluster peers found after waiting")
            :error

          nodes ->
            Logger.info("Cluster peers found: #{inspect(nodes)}")
            :ok
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

  defp call_beacon(message) do
    case find_beacon() do
      {:ok, pid} ->
        GenServer.call(pid, message)

      :error ->
        raise "BeaconServer.Beacon not found. Ensure beacon_server is running in the cluster."
    end
  end

  defp find_beacon do
    # Try Horde distributed registry first
    case Horde.Registry.lookup(BeaconServer.DistributedRegistry, :beacon) do
      [{pid, _}] -> {:ok, pid}
      _ -> find_beacon_local()
    end
  end

  defp find_beacon_local do
    case Process.whereis(BeaconServer.Beacon) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end
end
