defmodule DataService.Schema.VoxelTransactionCoordinatorSnapshot do
  @moduledoc """
  Single-row Ecto schema that stores the latest
  `WorldServer.Voxel.TransactionCoordinator` state as a serialized term blob.

  See `DataService.Voxel.TransactionCoordinatorStore` for the read/write helpers
  world_server uses; tests should not insert through this schema directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "voxel_transaction_coordinator_snapshots" do
    field(:payload, :binary)

    timestamps()
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:id, :payload])
    |> validate_required([:id, :payload])
  end
end
