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
      {WorldServer.Voxel.TransactionCoordinator, name: WorldServer.Voxel.TransactionCoordinator}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
