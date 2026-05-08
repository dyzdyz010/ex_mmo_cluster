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
       scene_opts_resolver: &__MODULE__.default_scene_opts_resolver/0}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Resolves `scene_opts` for `WorldServer.Voxel.TransactionRecoveryWatcher` by
  looking up the current Scene node through `BeaconServer`.

  Returns `{:ok, scene_opts}` when a Scene node has registered itself, or
  `{:error, :scene_unavailable}` when the registry has no entry yet
  (e.g. Watcher started before the Scene node finished joining the cluster).
  In the unavailable case the watcher leaves the transaction parked and
  emits `voxel_transaction_recovery_scene_opts_unavailable` for ops.

  Phase 3-bis assumes a single Scene node serves the world; once Phase 6
  introduces per-region coordinators we will route by region instead.
  """
  def default_scene_opts_resolver do
    case BeaconServer.Client.lookup(:scene_server) do
      {:ok, scene_node} ->
        {:ok, [scene_opts: [chunk_directory: {SceneServer.Voxel.ChunkDirectory, scene_node}]]}

      :error ->
        {:error, :scene_unavailable}
    end
  end
end
