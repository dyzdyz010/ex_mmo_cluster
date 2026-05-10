defmodule SceneServer.Voxel.RegionRouting do
  @moduledoc """
  Per-`scene_node` voxel region routing facade.

  Phase A4-bis-cluster step 2. Wraps `BeaconServer.Client` term-key
  registration (`{:voxel_region_scene_node, region_id}`) and provides
  the resolver functions used by:

  * `SceneServer.Voxel.ObjectOwnerLookup` — to learn the owner
    `scene_node` for a `scene_object` so cold-start cache fills point
    to the right node.
  * `SceneServer.Combat.VoxelDamageRouter` — to pick the
    `scene_node` to forward `accumulate_damage` calls to (see
    `:scene_node_resolver_fn` opt).
  * `SceneServer.Voxel.ObjectRegistry` — to translate a participant
    key (`{region_id, lease_id}`) into a `chunk_directory` target for
    `0x6C ObjectStateDelta` fan-out (see `:region_routing_fn` opt).

  ## Per-`scene_node` semantics (D10.B)

  Each scene_node hosts a single `ChunkDirectory` and a single
  `ObjectRegistry` instance. Same-BEAM regions resolve to the local
  module atom (`SceneServer.Voxel.ChunkDirectory`); cross-node regions
  resolve to a `{Mod, scene_node}` tuple, which `GenServer.call` /
  `cast` transparently route across the cluster.

  ## Test stubs

  Tests can install a static routing snapshot via `__install_stub__/1`
  (a `%{region_id => node()}` map) — `register/unregister` then become
  no-ops and `resolve_*` consults the snapshot instead of going to
  `BeaconServer.Client`. Use `__clear_stub__/0` in `on_exit/1` to
  reset. Backed by `:persistent_term` so cross-process `GenServer.call`
  paths see the same view.

  Wiring of these resolvers into `ObjectOwnerLookup` /
  `VoxelDamageRouter` / `ObjectRegistry` defaults happens in
  A4-bis-5; consumer call sites still pass through their existing
  `:scene_node_resolver_fn` / `:region_routing_fn` opts in this step.
  """

  @scene_node_resource_tag :voxel_region_scene_node
  @stub_pterm_key {__MODULE__, :stub_table}

  @typedoc "World-assigned region id."
  @type region_id :: non_neg_integer()

  @typedoc """
  World-issued lease id for a region. Reserved in the resolver
  signatures so future epoch-aware routing (lease drift / migration)
  doesn't require another signature change. Currently unused by
  production lookups (BeaconServer key drops `lease_id`).
  """
  @type lease_id :: term()

  @typedoc "Tuple form passed to `resolve_chunk_directory/1`."
  @type participant_key :: {region_id(), lease_id()}

  @typedoc """
  GenServer target for `ObjectRegistry` to dispatch `ChunkProcess`
  messages against:

  * a local module atom (same-BEAM region) →
    `SceneServer.Voxel.ChunkDirectory`
  * a `{Mod, scene_node}` tuple (cross-node region) — `GenServer.call`
    transparently hops to the remote BEAM
  * `nil` if the region isn't registered anywhere; callers retain
    the choice of falling back to a local default or dropping the
    delta with an observe event.
  """
  @type chunk_directory_target ::
          atom() | {atom(), node()} | nil

  @doc """
  Register the current node as the owner of `region_id` in the
  cluster-wide BeaconServer registry. Idempotent — returning `:ok`
  whether it's the first registration or a re-registration.

  Called by `RegionRuntime.apply_lease` (A4-bis-3).
  """
  @spec register_local_region(region_id(), keyword()) :: :ok | {:error, term()}
  def register_local_region(region_id, _opts \\ []) when is_integer(region_id) do
    if stub_active?() do
      :ok
    else
      BeaconServer.Client.register({@scene_node_resource_tag, region_id})
    end
  end

  @doc """
  Withdraw the current node's ownership claim for `region_id`.
  No-op if the caller process hasn't registered it.

  Called by `RegionRuntime` lease release / migration paths
  (A4-bis-3).
  """
  @spec unregister_local_region(region_id()) :: :ok
  def unregister_local_region(region_id) when is_integer(region_id) do
    if stub_active?() do
      :ok
    else
      BeaconServer.Client.unregister({@scene_node_resource_tag, region_id})
    end
  end

  @doc """
  Look up the `scene_node` currently owning `region_id`. Returns
  `:error` when no node has registered (region uninitialised, between
  lease handoffs, …); callers must treat that as "drop / route to
  local fallback / emit observe", not raise.

  `lease_id` is accepted but ignored by current production lookups.
  """
  @spec resolve_scene_node(region_id(), lease_id()) :: {:ok, node()} | :error
  def resolve_scene_node(region_id, _lease_id) when is_integer(region_id) do
    case stub_table() do
      :production ->
        BeaconServer.Client.lookup({@scene_node_resource_tag, region_id})

      table when is_map(table) ->
        case Map.fetch(table, region_id) do
          {:ok, node} when is_atom(node) -> {:ok, node}
          :error -> :error
        end
    end
  end

  @doc """
  Translate a `{region_id, lease_id}` participant key into a
  `ChunkDirectory` GenServer target, suitable for direct `call` /
  `cast`.

  Returns `nil` when the region's owner `scene_node` cannot be
  resolved; callers (e.g. `ObjectRegistry`) decide whether to fall
  back to a local instance or drop with a `voxel_*_dropped` observe.
  """
  @spec resolve_chunk_directory(participant_key()) :: chunk_directory_target()
  def resolve_chunk_directory({region_id, lease_id}) do
    case resolve_scene_node(region_id, lease_id) do
      {:ok, scene_node} when scene_node == node() ->
        SceneServer.Voxel.ChunkDirectory

      {:ok, scene_node} ->
        {SceneServer.Voxel.ChunkDirectory, scene_node}

      :error ->
        nil
    end
  end

  ## ── test helpers ──────────────────────────────────────────────────

  @doc false
  @spec __install_stub__(%{optional(region_id()) => node()}) :: :ok
  def __install_stub__(table) when is_map(table) do
    :persistent_term.put(@stub_pterm_key, table)
    :ok
  end

  @doc false
  @spec __clear_stub__() :: :ok
  def __clear_stub__ do
    case :persistent_term.get(@stub_pterm_key, :not_found) do
      :not_found ->
        :ok

      _ ->
        :persistent_term.erase(@stub_pterm_key)
        :ok
    end
  end

  @doc false
  @spec __stub_active__?() :: boolean()
  def __stub_active__?, do: stub_active?()

  defp stub_active? do
    :persistent_term.get(@stub_pterm_key, :not_found) != :not_found
  end

  defp stub_table do
    case :persistent_term.get(@stub_pterm_key, :not_found) do
      :not_found -> :production
      table -> table
    end
  end
end
