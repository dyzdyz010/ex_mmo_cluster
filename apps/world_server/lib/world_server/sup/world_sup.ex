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
      {WorldServer.Voxel.MapLedger,
       name: WorldServer.Voxel.MapLedger, write_token_store: DataService.Voxel.WriteTokenStore},
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
  `WorldServer.Voxel.TransactionRecoveryWatcher` resume path by looking up
  each participant's scene node through `BeaconServer`.

  Phase A4-1 changed the watcher contract from `0-arity → {:ok, [scene_opts:
  ...]}` to `1-arity(participants) → {:ok, [scene_opts_by_participant: %{...}]}`
  to match `TransactionExecutor.execute/4` per-participant API. Phase A4
  still uses a single global Scene node for all participants(BeaconServer
  registers `:scene_server` once); A4-2 will switch to per-region scene-node
  resolution via lease.

  Returns `{:ok, executor_opts}` when the Scene node is reachable, or
  `{:error, :scene_unavailable}` when the registry has no entry yet
  (e.g. watcher started before the Scene node finished joining). The
  watcher leaves the transaction parked and emits
  `voxel_transaction_recovery_scene_opts_unavailable` in that case.
  """
  def default_scene_opts_resolver(participants) when is_list(participants) do
    case BeaconServer.Client.lookup(:scene_server) do
      {:ok, scene_node} ->
        scene_opts_by_participant =
          Map.new(participants, fn participant ->
            {{participant.region_id, participant.lease_id},
             [chunk_directory: {SceneServer.Voxel.ChunkDirectory, scene_node}]}
          end)

        {:ok, [scene_opts_by_participant: scene_opts_by_participant]}

      :error ->
        {:error, :scene_unavailable}
    end
  end
end
