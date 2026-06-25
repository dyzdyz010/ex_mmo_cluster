defmodule GateServer.Voxel.SubscriptionWorker do
  @moduledoc """
  Per-connection voxel **subscription worker** (阶段4 step4.3 非阻塞核心).

  The gate connection used to route + subscribe every chunk of a subscribe box
  **synchronously inside its own GenServer** — 125 cold `safe_call`s (each up to
  15s) blocked the connection for a measured ~3.5s, stalling the player's queued
  `VoxelEditIntent` / movement frames. This worker moves that slow control-plane
  I/O off the connection's main loop: the connection `cast`s a reconcile intent
  and returns immediately, so edit / movement frames stay low-latency no matter
  how large the subscribe storm.

  Design:

  - **One worker per connection**, linked to it (dies with the connection). The
    worker holds the per-connection `RouteCache` (region ownership is stable, so a
    whole slab inside one region costs a single control-plane call — 阶段4 step4.4
    batch-route benefit comes for free via the cache).
  - It subscribes with `subscriber: connection_pid`, **not** itself, so chunk
    snapshots / deltas flow straight to the connection → socket (the fan-out hot
    path is untouched).
  - Results flow back to the connection as messages it applies on its own loop:
      * `{:voxel_subscribed, key, subscription}` — a chunk subscribed; the
        connection moves `key` from `voxel_pending` into `voxel_subscriptions`.
      * `{:voxel_subscribe_failed, error_ctx, reason}` — first routing/subscribe
        failure of a reconcile; the connection emits the `0x68` error frame.
      * `{:voxel_reconcile_settled, keys}` — end of a reconcile; the connection
        clears any of `keys` still pending (covers the failed coord and any coords
        skipped after an early halt, so `voxel_pending` never leaks).

  The connection has already diff'd the box against its live + pending
  subscriptions, so `ctx.coords` carries **only genuinely new** chunks (阶段4
  step4.2 差集).
  """

  use GenServer
  require Logger

  alias GateServer.Voxel.{Routing, RouteCache}

  @typedoc "Reconcile intent handed over from the connection (already diff'd)."
  @type reconcile_ctx :: %{
          request_id: non_neg_integer(),
          client_intent_seq: non_neg_integer(),
          logical_scene_id: integer(),
          want_snapshot: boolean(),
          coords: [{integer(), integer(), integer()}],
          known: %{optional({integer(), integer(), integer()}) => non_neg_integer()}
        }

  # ── public API ────────────────────────────────────────────────────────────

  @doc "Starts a worker bound to `connection_pid` (links to the caller)."
  @spec start_link(pid(), keyword()) :: GenServer.on_start()
  def start_link(connection_pid, opts \\ []) when is_pid(connection_pid) do
    GenServer.start_link(__MODULE__, {connection_pid, opts})
  end

  @doc "Asynchronously route + subscribe the (already diff'd) new chunks."
  @spec reconcile(pid(), reconcile_ctx()) :: :ok
  def reconcile(worker, ctx) when is_pid(worker) and is_map(ctx) do
    GenServer.cast(worker, {:reconcile, ctx})
  end

  @doc "Drops the worker's cached routes (e.g. on `ChunkInvalidate` / migration)."
  @spec invalidate_route_cache(pid()) :: :ok
  def invalidate_route_cache(worker) when is_pid(worker) do
    GenServer.cast(worker, :invalidate_route_cache)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init({connection_pid, opts}) do
    {:ok,
     %{
       connection_pid: connection_pid,
       route_cache: RouteCache.new(),
       refresh_window_ms: Keyword.get(opts, :route_cache_refresh_ms, :timer.seconds(30))
     }}
  end

  @impl true
  def handle_cast({:reconcile, ctx}, state) do
    {:noreply, do_reconcile(ctx, state)}
  end

  def handle_cast(:invalidate_route_cache, state) do
    {:noreply, %{state | route_cache: RouteCache.new()}}
  end

  # ── reconcile ─────────────────────────────────────────────────────────────

  defp do_reconcile(%{coords: coords} = ctx, state) do
    now = System.system_time(:millisecond)
    batch_keys = Enum.map(coords, &{ctx.logical_scene_id, &1})

    final_state =
      Enum.reduce_while(coords, state, fn coord, acc ->
        case subscribe_one(acc, ctx, coord, now) do
          {:ok, next_acc} -> {:cont, next_acc}
          {:error, reason, next_acc} -> {:halt, fail(next_acc, ctx, reason)}
        end
      end)

    send(state.connection_pid, {:voxel_reconcile_settled, batch_keys})
    final_state
  end

  defp subscribe_one(state, ctx, coord, now) do
    with {:ok, route, state} <- route_cached(state, ctx.logical_scene_id, coord, now),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      attrs = %{
        request_id: ctx.request_id,
        logical_scene_id: ctx.logical_scene_id,
        chunk_coord: coord,
        subscriber: state.connection_pid,
        lease: lease,
        send_snapshot?: ctx.want_snapshot,
        known_version: Map.get(ctx.known, coord)
      }

      case Routing.subscribe(scene_node, attrs) do
        {:ok, _payload} ->
          subscription = %{
            logical_scene_id: ctx.logical_scene_id,
            chunk_coord: coord,
            request_id: ctx.request_id,
            scene_node: scene_node,
            region_id: lease.region_id,
            lease_id: lease.lease_id,
            owner_scene_instance_ref: lease.owner_scene_instance_ref,
            owner_epoch: lease.owner_epoch
          }

          emit_routed(state, ctx, coord, route)
          send(state.connection_pid, {:voxel_subscribed, {ctx.logical_scene_id, coord}, subscription})
          {:ok, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # cache-first per-chunk route: a hit returns locally; a miss routes through the
  # control plane (materializing the region) and caches it. Lease-near-expiry is a
  # cache miss, so the re-route triggers a World-side renewal (阶段2-bis).
  defp route_cached(state, logical_scene_id, chunk_coord, now) do
    case RouteCache.lookup(state.route_cache, chunk_coord, now, state.refresh_window_ms) do
      {:ok, route} ->
        {:ok, route, state}

      :miss ->
        case Routing.route_chunk(logical_scene_id, chunk_coord) do
          {:ok, route} ->
            cache = RouteCache.put(state.route_cache, route, now)
            {:ok, route, %{state | route_cache: cache}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fail(state, ctx, reason) do
    send(
      state.connection_pid,
      {:voxel_subscribe_failed,
       %{
         request_id: ctx.request_id,
         client_intent_seq: ctx.client_intent_seq,
         logical_scene_id: ctx.logical_scene_id
       }, reason}
    )

    state
  end

  defp emit_routed(state, ctx, coord, route) do
    GateServer.CliObserve.emit("voxel_chunk_subscribe_routed", fn ->
      assignment = Map.fetch!(route, :assignment)
      lease = Map.fetch!(route, :lease)

      %{
        connection_pid: state.connection_pid,
        request_id: ctx.request_id,
        logical_scene_id: ctx.logical_scene_id,
        center_chunk: coord,
        region_id: assignment.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch
      }
    end)
  end
end
