defmodule WorldServer.Voxel.SceneNodeRegistry do
  @moduledoc """
  World-side membership map of scene_nodes and the regions assigned to
  each (Phase A4-bis-cluster step 4 — D8.B *join-order round-robin*).

  Authoritative on the World side. The Scene side counterpart is
  `SceneServer.Voxel.RegionRouting` (per-node BeaconServer registration);
  this module records *which* regions have been allocated to *which*
  scene_node so subsequent transactions know where to dispatch
  per-participant scene_opts.

  ## Assignment policy (D8.B)

  * Scene_nodes register through `register_scene_node/2` (e.g. via a
    BeaconServer subscriber, or directly in tests). The order of first
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

  ## Wiring (deferred to A4-bis-4 segment 2)

  This module is intentionally *not* wired into supervision tree or
  to a BeaconServer subscriber yet — segment 1 lands the standalone
  module + tests. Segment 2 will:

  * Mount it under `WorldServer.WorldSup`.
  * Subscribe to `BeaconServer.DistributedRegistry` for `:scene_server`
    join / leave events to feed `register_scene_node/2` /
    `unregister_scene_node/2`.
  * Wire `MapLedger.put_region` to call `assign_region/2` and persist
    the resulting `assigned_scene_node` to the region row.
  * Replace `world_sup.default_scene_opts_resolver/1` to use
    `lookup_assignment/2` per participant.
  """

  use GenServer

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
  def init(_opts) do
    {:ok,
     %{
       join_order: [],
       region_assignments: %{},
       round_robin_cursor: 0
     }}
  end

  @impl true
  def handle_call({:register_scene_node, node}, _from, state) do
    if node in state.join_order do
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | join_order: state.join_order ++ [node]}}
    end
  end

  def handle_call({:unregister_scene_node, node}, _from, state) do
    new_join_order = List.delete(state.join_order, node)

    new_cursor =
      case new_join_order do
        [] -> 0
        nodes -> rem(state.round_robin_cursor, length(nodes))
      end

    {:reply, :ok, %{state | join_order: new_join_order, round_robin_cursor: new_cursor}}
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

            new_state = %{
              state
              | region_assignments: Map.put(state.region_assignments, region_id, chosen),
                round_robin_cursor: state.round_robin_cursor + 1
            }

            {:reply, {:ok, chosen}, new_state}
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
end
