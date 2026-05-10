defmodule WorldServer.WorldSup do
  @moduledoc """
  This is the World Supervisor.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      # Phase A4-bis-cluster step 4 (segment 2a → 2c): start
      # SceneNodeRegistry + SceneNodeMonitor *before* MapLedger so
      # MapLedger.put_region can consult the registry from its very
      # first call. SceneNodeRegistry is the state, SceneNodeMonitor
      # sweeps it on `:nodedown`.
      {WorldServer.Voxel.SceneNodeRegistry, name: WorldServer.Voxel.SceneNodeRegistry},
      {WorldServer.Voxel.SceneNodeMonitor,
       name: WorldServer.Voxel.SceneNodeMonitor, registry: WorldServer.Voxel.SceneNodeRegistry},
      {WorldServer.Voxel.MapLedger,
       name: WorldServer.Voxel.MapLedger,
       write_token_store: DataService.Voxel.WriteTokenStore,
       scene_node_registry: WorldServer.Voxel.SceneNodeRegistry},
      {WorldServer.Voxel.TransactionCoordinator,
       name: WorldServer.Voxel.TransactionCoordinator,
       persist_fn: DataService.Voxel.TransactionCoordinatorStore.persist_fn(DataService.Repo),
       load_fn: DataService.Voxel.TransactionCoordinatorStore.load_fn(DataService.Repo)},
      {WorldServer.Voxel.TransactionRecoveryWatcher,
       name: WorldServer.Voxel.TransactionRecoveryWatcher,
       coordinator: WorldServer.Voxel.TransactionCoordinator,
       scene_opts_resolver: &__MODULE__.default_scene_opts_resolver/1}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Resolves `:scene_opts_by_participant` for the
  `WorldServer.Voxel.TransactionRecoveryWatcher` resume path by looking
  up **each participant's** scene_node from `MapLedger` (Phase A4-bis-4
  段 2d).

  Each participant's `region_id` is resolved through
  `MapLedger.lookup_region_scene_node/2` (which reads the
  `RegionAssignment.assigned_scene_node` filled in by `put_region` from
  `SceneNodeRegistry.assign_region/2`). A `chunk_directory` target of
  `{SceneServer.Voxel.ChunkDirectory, scene_node}` is built per
  participant — single-BEAM dev / single-`scene_node` deployment ends
  up with all participants pointing at the same node, multi-`scene_node`
  deployments naturally route to different nodes.

  Returns:

  * `{:ok, executor_opts}` — at least one participant resolved, all
    resolved participants are in the per-participant opts map.
    Unresolved participants (region not yet assigned to a scene_node)
    are dropped from the map; the executor will fail those participants
    individually later. *Open question:* should we instead fail the whole
    resume here? For now, partial-resolution lets the executor
    distinguish "per-participant prepare failure" from "world routing
    failure" in observe.
  * `{:error, :scene_unavailable}` — *no* participant has an assigned
    scene_node. Watcher leaves the transaction parked and emits
    `voxel_transaction_recovery_scene_opts_unavailable`.
  """
  def default_scene_opts_resolver(participants) when is_list(participants),
    do: default_scene_opts_resolver(participants, [])

  @doc """
  Same as `default_scene_opts_resolver/1` but with injectable opts —
  used by tests that need to point at a per-test isolated MapLedger
  rather than the production global `WorldServer.Voxel.MapLedger`.

  Opts:

  * `:ledger` — `MapLedger` GenServer name / pid (default
    `WorldServer.Voxel.MapLedger`).
  """
  def default_scene_opts_resolver(participants, opts) when is_list(participants) do
    ledger = Keyword.get(opts, :ledger, WorldServer.Voxel.MapLedger)

    pairs =
      Enum.flat_map(participants, fn participant ->
        case WorldServer.Voxel.MapLedger.lookup_region_scene_node(
               ledger,
               participant.region_id
             ) do
          {:ok, scene_node} ->
            [
              {{participant.region_id, participant.lease_id},
               [chunk_directory: {SceneServer.Voxel.ChunkDirectory, scene_node}]}
            ]

          :error ->
            []
        end
      end)

    case pairs do
      [] ->
        {:error, :scene_unavailable}

      _ ->
        {:ok, [scene_opts_by_participant: Map.new(pairs)]}
    end
  end
end
