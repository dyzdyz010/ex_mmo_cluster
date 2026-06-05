defmodule WorldServer.Voxel.SceneNodeRegistry do
  @moduledoc """
  World-side membership map of scene_nodes and the regions assigned to
  each (Phase A4-bis-cluster step 4 — D8.B *join-order round-robin*).

  Authoritative on the World side. The Scene side counterpart is
  `SceneServer.Voxel.RegionRouting` (per-node BeaconServer registration);
  this module records *which* regions have been allocated to *which*
  scene_node so subsequent transactions know where to dispatch
  per-participant scene_opts.

  ## Source of truth (Phase 3 / S1 — process identity registration)

  Region ownership is **durable**. The authoritative record lives in
  Postgres (`voxel_scene_node_registry_snapshots`, behind
  `DataService.Voxel.SceneNodeRegistryStore`); this GenServer's in-memory
  `join_order` / `region_assignments` / `round_robin_cursor` is a *derived
  cache* hydrated from that row on every (re)start. A crash/restart of this
  process must not lose region assignments:

  * `init/1` runs `load_fn` and hydrates the cache from the row. There is no
    "memory is the only truth" fallback — a fresh deploy starts empty because
    the *row* is empty, not because we default to empty on error.
  * Every mutation (`register_scene_node/2`, `unregister_scene_node/2`,
    `assign_region/2`) upserts the row through `persist_fn` before replying, so
    the durable record never lags the in-memory cache.
  * A load that hits a *corrupt / unexpected* row degrades to empty defaults and
    emits `voxel_scene_node_registry_hydrate_failed` (the row is preserved for
    inspection; we never silently treat a malformed row as authoritative). An
    *empty* table is the normal fresh-deploy path and hydrates to empty without
    any warning.

  Without `persist_fn` / `load_fn` (e.g. focused unit tests) the registry runs
  pure in-memory — useful for isolation, but production wiring in
  `WorldServer.WorldSup` always injects the Postgres-backed functions.

  ## Assignment policy (D8.B)

  * Scene_nodes register through `register_scene_node/2` (announced from
    `SceneServer.Interface` via RPC, or directly in tests). The order of first
    registration is preserved as `join_order`.
  * `assign_region/2` picks the next scene_node from `join_order` in
    round-robin fashion. Once assigned, a region's owner is **frozen**
    — calling `assign_region/2` again with the same `region_id` returns
    the existing assignment unchanged (idempotent). This avoids
    runtime hand-off churn at the cost of less-than-perfectly-balanced
    long-running clusters; runtime rebalancing is Phase 6 HA scope.
  * `unregister_scene_node/2` removes a node from the round-robin
    rotation but **does not reassign** its existing regions — those
    become unreachable until the node rejoins (MVP per D8.B; Phase 6
    HA adds failover).

  ## Cluster liveness

  `WorldServer.Voxel.SceneNodeMonitor` owns `:net_kernel.monitor_nodes`
  liveness and reconciles the hydrated `join_order` against the currently
  connected node set on its own (re)start, sweeping nodes that died while this
  process / the monitor was down. The registry itself stays free of cluster
  lifecycle concerns.
  """

  use GenServer
  require Logger

  alias WorldServer.CliObserve

  @durable_keys [:join_order, :region_assignments, :round_robin_cursor]

  ## ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Append `node` to the join order if not already present. Idempotent —
  re-registering an existing node is a no-op (preserves original
  position in `join_order`).
  """
  @spec register_scene_node(GenServer.server(), node()) :: :ok
  def register_scene_node(server \\ __MODULE__, node) when is_atom(node) do
    GenServer.call(server, {:register_scene_node, node})
  end

  @doc """
  Remove `node` from the join order. Existing region assignments
  remain — those regions become unreachable until the node rejoins.
  No-op when the node was never registered.
  """
  @spec unregister_scene_node(GenServer.server(), node()) :: :ok
  def unregister_scene_node(server \\ __MODULE__, node) when is_atom(node) do
    GenServer.call(server, {:unregister_scene_node, node})
  end

  @doc """
  Pick (or return the existing) scene_node assignment for `region_id`.

  Returns `{:ok, node}` when a scene_node is available (or this region
  was previously assigned), or `{:error, :no_scene_nodes}` when no
  scene_nodes are currently registered and the region has no prior
  assignment.

  Idempotent: calling repeatedly with the same `region_id` returns the
  same assignment (no rebalancing).
  """
  @spec assign_region(GenServer.server(), non_neg_integer()) ::
          {:ok, node()} | {:error, :no_scene_nodes}
  def assign_region(server \\ __MODULE__, region_id) when is_integer(region_id) do
    GenServer.call(server, {:assign_region, region_id})
  end

  @doc """
  Look up the scene_node currently owning `region_id`. Returns
  `{:ok, node}` or `:error`. Read-only — does *not* assign on miss.
  """
  @spec lookup_assignment(GenServer.server(), non_neg_integer()) ::
          {:ok, node()} | :error
  def lookup_assignment(server \\ __MODULE__, region_id) when is_integer(region_id) do
    GenServer.call(server, {:lookup_assignment, region_id})
  end

  @doc """
  Reconcile `join_order` against a known-live node set, dropping any
  registered scene_node not in `live_nodes`.

  Called by `WorldServer.Voxel.SceneNodeMonitor` on (re)start to sweep
  scene_nodes that disconnected while monitoring was not established (e.g. a
  registry/monitor restart after hydrating stale entries from Postgres).
  Region assignments for swept nodes are intentionally left in place, matching
  `unregister_scene_node/2` semantics (those regions become unreachable until
  the node rejoins). Returns the list of swept nodes.
  """
  @spec reconcile_live_nodes(GenServer.server(), [node()]) :: {:ok, [node()]}
  def reconcile_live_nodes(server \\ __MODULE__, live_nodes) when is_list(live_nodes) do
    GenServer.call(server, {:reconcile_live_nodes, live_nodes})
  end

  @doc "Return the full state for inspection / tests."
  @spec snapshot(GenServer.server()) :: %{
          join_order: [node()],
          region_assignments: %{non_neg_integer() => node()}
        }
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  ## ── Server callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    persist_fn = Keyword.get(opts, :persist_fn)
    load_fn = Keyword.get(opts, :load_fn)

    base = %{
      join_order: [],
      region_assignments: %{},
      round_robin_cursor: 0,
      persist_fn: persist_fn
    }

    {:ok, hydrate(base, load_fn)}
  end

  @impl true
  def handle_call({:register_scene_node, node}, _from, state) do
    if node in state.join_order do
      {:reply, :ok, state}
    else
      persist_reply(:ok, %{state | join_order: state.join_order ++ [node]})
    end
  end

  def handle_call({:unregister_scene_node, node}, _from, state) do
    if node in state.join_order do
      persist_reply(:ok, drop_node(state, node))
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:reconcile_live_nodes, live_nodes}, _from, state) do
    stale = Enum.reject(state.join_order, &(&1 in live_nodes))

    case stale do
      [] ->
        {:reply, {:ok, []}, state}

      _ ->
        next_state = Enum.reduce(stale, state, &drop_node(&2, &1))
        persist_reply({:ok, stale}, next_state)
    end
  end

  def handle_call({:assign_region, region_id}, _from, state) do
    case Map.fetch(state.region_assignments, region_id) do
      {:ok, node} ->
        {:reply, {:ok, node}, state}

      :error ->
        case state.join_order do
          [] ->
            {:reply, {:error, :no_scene_nodes}, state}

          nodes ->
            chosen = Enum.at(nodes, rem(state.round_robin_cursor, length(nodes)))

            next_state = %{
              state
              | region_assignments: Map.put(state.region_assignments, region_id, chosen),
                round_robin_cursor: state.round_robin_cursor + 1
            }

            persist_reply({:ok, chosen}, next_state)
        end
    end
  end

  def handle_call({:lookup_assignment, region_id}, _from, state) do
    case Map.fetch(state.region_assignments, region_id) do
      {:ok, node} -> {:reply, {:ok, node}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:join_order, :region_assignments]), state}
  end

  ## ── Internal ──────────────────────────────────────────────────────

  # Remove `node` from the rotation, keeping the cursor in range. Region
  # assignments are intentionally preserved (D8.B MVP — no auto-failover).
  defp drop_node(state, node) do
    new_join_order = List.delete(state.join_order, node)

    new_cursor =
      case new_join_order do
        [] -> 0
        nodes -> rem(state.round_robin_cursor, length(nodes))
      end

    %{state | join_order: new_join_order, round_robin_cursor: new_cursor}
  end

  # Persist the durable slice of `next_state` before replying. A persist
  # failure does not roll back the in-memory cache (the row will catch up on
  # the next successful mutation or on rehydrate); we surface it via observe so
  # the divergence is visible. This mirrors `MapLedger` / `TransactionCoordinator`.
  defp persist_reply(reply, next_state) do
    case run_persist(next_state) do
      :ok ->
        {:reply, reply, next_state}

      {:error, reason} ->
        CliObserve.emit("voxel_scene_node_registry_persist_failed", fn ->
          %{reason: inspect(reason)}
        end)

        {:reply, reply, next_state}
    end
  end

  defp run_persist(%{persist_fn: nil}), do: :ok

  defp run_persist(%{persist_fn: persist_fn} = state) when is_function(persist_fn, 1) do
    persist_fn.(Map.take(state, @durable_keys))
  end

  # Restart-from-authority hydrate. The row is the source of truth; the empty
  # table is the normal fresh-deploy path. A corrupt / unexpected row degrades
  # to empty defaults *with* an observe signal — we never treat a malformed row
  # as authoritative, and we never crash the registry over a bad row.
  defp hydrate(base, nil), do: base

  defp hydrate(base, load_fn) when is_function(load_fn, 0) do
    case run_load(load_fn) do
      {:ok, restored} ->
        Map.merge(base, restored)

      {:error, reason} ->
        CliObserve.emit("voxel_scene_node_registry_hydrate_failed", fn ->
          %{reason: inspect(reason)}
        end)

        base
    end
  end

  defp run_load(load_fn) do
    case load_fn.() do
      {:ok, payload} when is_map(payload) -> validate_loaded_payload(payload)
      {:error, _reason} = err -> err
      other -> {:error, {:unexpected_load_result, other}}
    end
  end

  # An empty map means "no row yet" → hydrate to base defaults. A non-empty
  # payload must carry only durable keys with the right shapes; the store
  # already enforces this, but we re-check here so a future load_fn source can't
  # smuggle a transient key into the cache.
  defp validate_loaded_payload(payload) when map_size(payload) == 0, do: {:ok, %{}}

  defp validate_loaded_payload(payload) do
    keys = Map.keys(payload)

    cond do
      Enum.any?(keys, fn key -> key not in @durable_keys end) ->
        {:error, {:unexpected_keys, keys -- @durable_keys}}

      not (is_list(Map.get(payload, :join_order, [])) and
               Enum.all?(Map.get(payload, :join_order, []), &is_atom/1)) ->
        {:error, :unexpected_join_order_shape}

      not is_map(Map.get(payload, :region_assignments, %{})) ->
        {:error, :unexpected_region_assignments_shape}

      not (is_integer(Map.get(payload, :round_robin_cursor, 0)) and
               Map.get(payload, :round_robin_cursor, 0) >= 0) ->
        {:error, :unexpected_round_robin_cursor_shape}

      true ->
        {:ok, payload}
    end
  end
end
