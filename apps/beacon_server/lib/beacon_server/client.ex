defmodule BeaconServer.Client do
  @moduledoc """
  Service discovery client using Horde distributed registry.

  Each app registers its resource name (e.g. :scene_server) in the
  distributed registry. Consumers look up services directly by name.

  No central coordinator — fully distributed via Horde.Registry.

  ## Usage

      # Register this node as a :scene_server
      BeaconServer.Client.register(:scene_server)

      # Look up where :scene_server is running
      {:ok, node} = BeaconServer.Client.lookup(:scene_server)

      # Wait for a service to become available (with retry)
      {:ok, node} = BeaconServer.Client.await(:data_contact, timeout: 30_000)
  """

  require Logger

  @registry BeaconServer.DistributedRegistry

  @doc """
  Join the cluster via libcluster. Waits briefly for peer discovery.
  """
  @spec join_cluster() :: :ok | :error
  def join_cluster do
    case Node.list() do
      [] ->
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
  Register the current process as a provider of the given service.
  Stores `node()` as the value so consumers can find which node provides it.
  """
  @spec register(atom()) :: :ok | {:error, term()}
  def register(resource) do
    case Horde.Registry.register(@registry, resource, node()) do
      {:ok, _} ->
        Logger.info("Registered #{resource} in distributed registry")
        :ok
      {:error, {:already_registered, _}} ->
        Logger.info("#{resource} already registered")
        :ok
      {:error, reason} ->
        Logger.error("Failed to register #{resource}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Look up which node provides the given service.
  Returns `{:ok, node}` or `:error`.
  """
  @spec lookup(atom()) :: {:ok, node()} | :error
  def lookup(resource) do
    case Horde.Registry.lookup(@registry, resource) do
      [{_pid, node}] -> {:ok, node}
      _ -> :error
    end
  end

  @doc """
  Wait for a service to become available, retrying with interval.

  Options:
  - `:timeout` — max wait time in ms (default: 30_000)
  - `:interval` — retry interval in ms (default: 1_000)
  """
  @spec await(atom(), keyword()) :: {:ok, node()} | :timeout
  def await(resource, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    interval = Keyword.get(opts, :interval, 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await(resource, interval, deadline)
  end

  defp do_await(resource, interval, deadline) do
    case lookup(resource) do
      {:ok, node} ->
        {:ok, node}
      :error ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(interval)
          do_await(resource, interval, deadline)
        end
    end
  end
end
