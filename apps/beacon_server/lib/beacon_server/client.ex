defmodule BeaconServer.Client do
  @moduledoc """
  Service discovery client using Horde distributed registry.

  Each app registers a resource key (atom or any term) in the
  distributed registry. Consumers look up services directly by key.

  No central coordinator — fully distributed via Horde.Registry.

  ## Resource keys

  Resource keys may be any Erlang term. The two common shapes:

  - **Atom keys** for module-level singletons:
    `:scene_server`, `:auth_server`, `:voxel_transaction_coordinator` …
  - **Tuple keys** for parameterized resources (e.g. one entry per
    region / shard / tenant):
    `{:voxel_region_scene_node, region_id}`,
    `{:voxel_region_chunk_directory, region_id}` …

  ## Usage

      # Register this node as a :scene_server
      BeaconServer.Client.register(:scene_server)

      # Look up where :scene_server is running
      {:ok, node} = BeaconServer.Client.lookup(:scene_server)

      # Wait for a service to become available (with retry)
      {:ok, node} = BeaconServer.Client.await(:scene_server, timeout: 30_000)

      # Tuple key — register the scene_node that hosts a region
      BeaconServer.Client.register({:voxel_region_scene_node, region_id})
      {:ok, node} = BeaconServer.Client.lookup({:voxel_region_scene_node, region_id})
  """

  require Logger

  @registry BeaconServer.DistributedRegistry

  @doc """
  Join the cluster via libcluster. Waits briefly for peer discovery.

  When cluster discovery is intentionally disabled, this returns `:error`
  without waiting or logging peer-missing warnings; local Horde registration can
  still be used by tests and single-node runtimes.
  """
  @spec join_cluster() :: :ok | :error
  def join_cluster do
    if cluster_disabled?() do
      :error
    else
      wait_for_cluster_peers()
    end
  end

  defp wait_for_cluster_peers do
    case Node.list() do
      [] ->
        Process.sleep(1000)

        case Node.list() do
          [] ->
            Logger.info("No cluster peers found after waiting; continuing in single-node mode")
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

  defp cluster_disabled? do
    Application.get_env(:beacon_server, :disable_cluster, false) ||
      System.get_env("DISABLE_CLUSTER") in ["true", "1"] ||
      mix_test_env?()
  end

  defp mix_test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  @typedoc """
  Resource key for service discovery. Atoms for module-level singletons,
  tuples for parameterized resources (e.g. `{:voxel_region_scene_node, id}`).
  """
  @type resource_key :: term()

  @doc """
  Register the current process as a provider of the given resource.
  Stores `node()` as the value so consumers can find which node provides it.

  `resource` may be any term — an atom for a singleton service, or a tuple
  for a parameterized one (see module doc).
  """
  @spec register(resource_key()) :: :ok | {:error, term()}
  def register(resource) do
    case Horde.Registry.register(@registry, resource, node()) do
      {:ok, _} ->
        confirm_registered(resource, "Registered #{inspect(resource)} in distributed registry")

      {:error, {:already_registered, _}} ->
        confirm_registered(resource, "#{inspect(resource)} already registered")

      {:error, reason} ->
        Logger.error("Failed to register #{inspect(resource)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp confirm_registered(resource, message) do
    case await(resource, timeout: 1_000, interval: 10) do
      {:ok, _node} ->
        Logger.info(message)
        :ok

      :timeout ->
        reason = :registration_not_visible
        Logger.error("Failed to observe #{inspect(resource)} after registration")
        {:error, reason}
    end
  end

  @doc """
  Look up which node provides the given resource.
  Returns `{:ok, node}` or `:error`.
  """
  @spec lookup(resource_key()) :: {:ok, node()} | :error
  def lookup(resource) do
    case Horde.Registry.lookup(@registry, resource) do
      [{_pid, node}] -> {:ok, node}
      _ -> :error
    end
  end

  @doc """
  Wait for a resource to become available, retrying with interval.

  Options:
  - `:timeout` — max wait time in ms (default: 30_000)
  - `:interval` — retry interval in ms (default: 1_000)
  """
  @spec await(resource_key(), keyword()) :: {:ok, node()} | :timeout
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

  @doc """
  Unregister the calling process for `resource`. No-op when the caller
  has no registration. Always returns `:ok`.

  Horde.Registry's `unregister/2` matches on the calling process; only
  the owner can withdraw its own entry. Cross-process / cross-node
  withdrawal requires the owner to call this itself, or for the owner
  process to exit (entry is then reaped by Horde).
  """
  @spec unregister(resource_key()) :: :ok
  def unregister(resource) do
    Horde.Registry.unregister(@registry, resource)
    :ok
  end
end
