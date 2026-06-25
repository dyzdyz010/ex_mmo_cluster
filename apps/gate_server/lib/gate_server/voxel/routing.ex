defmodule GateServer.Voxel.Routing do
  @moduledoc """
  Shared voxel routing + scene-subscription I/O for gate connections and the
  per-connection `GateServer.Voxel.SubscriptionWorker` (阶段4 step4.1 去镜像).

  Previously every one of these calls was mirrored byte-for-byte across
  `tcp_connection` and `ws_connection`. Centralising them here gives a single
  implementation the worker and both connections (edit / rebind paths) share, so
  the routing contract can never drift between transports.

  Every node call goes through `safe_call/3` — a crash-safe `GenServer.call` that
  degrades a dead World / Scene node to a tagged `{:error, _}` instead of taking
  the caller process down.
  """

  @default_call_timeout 15_000

  @doc "Resolves the World node, or `{:error, :world_unavailable}`."
  @spec world_node() :: {:ok, node()} | {:error, :world_unavailable}
  def world_node, do: fetch_node(:world_server, :world_unavailable)

  @doc "Resolves a Scene node, or `{:error, :scene_unavailable}`."
  @spec scene_node() :: {:ok, node()} | {:error, :scene_unavailable}
  def scene_node, do: fetch_node(:scene_server, :scene_unavailable)

  defp fetch_node(resource, unavailable) do
    case safe_call(GateServer.Interface, resource) do
      {:ok, nil} -> {:error, unavailable}
      {:ok, node} -> {:ok, node}
      {:error, _reason} -> {:error, unavailable}
    end
  end

  @doc """
  Routes one chunk through the World control plane, **materializing** the owning
  region on a route miss (route-miss → lazy region, 阶段1). The world is therefore
  unbounded: any reachable chunk yields a writable region. A genuine failure (no
  Scene node to host the new region, World down) is returned as `{:error, _}`.
  """
  @spec route_chunk(integer(), {integer(), integer(), integer()}, timeout()) ::
          {:ok, map()} | {:error, term()}
  def route_chunk(logical_scene_id, chunk_coord, timeout \\ @default_call_timeout) do
    with {:ok, world_node} <- world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_chunk_with_lease_ensuring, logical_scene_id, chunk_coord},
             timeout
           ) do
        {:ok, {:ok, route}} -> {:ok, route}
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  @doc "Batch variant of `route_chunk/3` — one World call for a whole slab."
  @spec route_chunks(integer(), [{integer(), integer(), integer()}], timeout()) ::
          {:ok, term()} | {:error, term()}
  def route_chunks(logical_scene_id, chunk_coords, timeout \\ @default_call_timeout) do
    with {:ok, world_node} <- world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_chunks_with_leases_ensuring, logical_scene_id, chunk_coords},
             timeout
           ) do
        {:ok, {:ok, routes}} -> {:ok, routes}
        {:ok, {:error, _reason}} -> {:error, :no_route_for_chunk}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  @doc "Extracts the assigned Scene node from a route, or `:scene_node_unassigned`."
  @spec scene_node_for_route(map()) :: {:ok, node()} | {:error, :scene_node_unassigned}
  def scene_node_for_route(%{assignment: %{assigned_scene_node: scene_node}})
      when not is_nil(scene_node),
      do: {:ok, scene_node}

  def scene_node_for_route(_route), do: {:error, :scene_node_unassigned}

  @doc """
  Subscribes `attrs.subscriber` to a chunk via the Scene's `ChunkDirectory`.
  Returns `{:ok, payload}` (the snapshot was already pushed to the subscriber when
  warranted) or a tagged error.
  """
  @spec subscribe(node(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def subscribe(scene_node, attrs, timeout \\ @default_call_timeout) do
    case safe_call(
           {SceneServer.Voxel.ChunkDirectory, scene_node},
           {:subscribe, attrs},
           timeout
         ) do
      {:ok, {:ok, payload}} -> {:ok, payload}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
      # A call **timeout** means the outcome is unknown — ChunkProcess registers the
      # subscriber (`put_subscriber`) BEFORE encoding the snapshot, so a slow cold
      # subscribe very likely already subscribed at the Scene. Surface it distinctly
      # so the caller can record a tentative subscription instead of treating it as a
      # clean failure (which would leak the Scene-side subscriber). Hard exits
      # (noproc / nodedown) definitely did not register → :scene_unavailable.
      {:error, {:timeout, _}} -> {:error, :timeout}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  @doc "Best-effort unsubscribe of `attrs.subscriber` from a chunk (always `:ok`)."
  @spec unsubscribe(node(), map(), timeout()) :: :ok
  def unsubscribe(scene_node, attrs, timeout \\ @default_call_timeout) do
    _ =
      safe_call(
        {SceneServer.Voxel.ChunkDirectory, scene_node},
        {:unsubscribe, attrs},
        timeout
      )

    :ok
  end

  @doc "Crash-safe `GenServer.call`: `{:ok, reply}` or `{:error, exit_reason}`."
  @spec safe_call(GenServer.server() | nil, term(), timeout()) :: {:ok, term()} | {:error, term()}
  def safe_call(server, message, timeout \\ @default_call_timeout)
  def safe_call(nil, _message, _timeout), do: {:error, :unavailable}

  def safe_call(server, message, timeout) do
    {:ok, GenServer.call(server, message, timeout)}
  catch
    :exit, reason -> {:error, reason}
  end
end
