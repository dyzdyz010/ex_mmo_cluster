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
       coordinator: WorldServer.Voxel.TransactionCoordinator}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
