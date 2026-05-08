defmodule DataService.Schema.VoxelChunkPendingTransaction do
  @moduledoc """
  Canonical Ecto schema for one in-flight voxel chunk fence row.

  Mirrors the `voxel_chunk_pending_transactions` table created by
  `DataService.Repo.Migrations.CreateVoxelChunkPendingTransactions`. Each row
  represents `SceneServer.Voxel.ChunkProcess.pending_fence` for one chunk.

  The composite identity is `(logical_scene_id, coord_x, coord_y, coord_z)` —
  same shape as `DataService.Schema.VoxelChunkSnapshot`, so a chunk has at
  most one fence at any moment. Ecto requires every component marked
  `primary_key: true` for `Repo.get_by/2` and inserts to work without a
  surrogate key.

  See `docs/voxel-server-authority/phase-3-bis-fence-and-resume.md` for the
  decision context.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  schema "voxel_chunk_pending_transactions" do
    field(:logical_scene_id, :integer, primary_key: true)
    field(:coord_x, :integer, primary_key: true)
    field(:coord_y, :integer, primary_key: true)
    field(:coord_z, :integer, primary_key: true)
    field(:transaction_id, :binary)
    field(:decision_version, :integer)
    field(:owner_region_id, :integer)
    field(:owner_lease_id, :integer)
    field(:owner_scene_instance_ref, :integer)
    field(:owner_epoch, :integer)
    field(:fence_payload, :binary)
    field(:fenced_at_ms, :integer)

    timestamps()
  end

  @required_fields [
    :logical_scene_id,
    :coord_x,
    :coord_y,
    :coord_z,
    :transaction_id,
    :decision_version,
    :owner_region_id,
    :owner_lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :fence_payload,
    :fenced_at_ms
  ]

  @nonneg_fields [
    :logical_scene_id,
    :decision_version,
    :owner_region_id,
    :owner_lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :fenced_at_ms
  ]

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_nonneg(@nonneg_fields)
    |> validate_transaction_id_nonempty()
    |> validate_fence_payload_nonempty()
    |> unique_constraint(
      [:logical_scene_id, :coord_x, :coord_y, :coord_z],
      name: :voxel_chunk_pending_transactions_pkey,
      error_key: :logical_scene_id,
      message: "fence already present"
    )
  end

  defp validate_nonneg(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_field(acc, field) do
        value when is_integer(value) and value < 0 ->
          add_error(acc, field, "must be >= 0")

        _ ->
          acc
      end
    end)
  end

  defp validate_transaction_id_nonempty(changeset) do
    case get_field(changeset, :transaction_id) do
      <<>> -> add_error(changeset, :transaction_id, "must not be empty")
      _ -> changeset
    end
  end

  defp validate_fence_payload_nonempty(changeset) do
    case get_field(changeset, :fence_payload) do
      <<>> -> add_error(changeset, :fence_payload, "must not be empty")
      _ -> changeset
    end
  end
end
