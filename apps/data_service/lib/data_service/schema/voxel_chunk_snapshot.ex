defmodule DataService.Schema.VoxelChunkSnapshot do
  @moduledoc """
  Canonical Ecto schema for the voxel chunk truth row.

  Mirrors the `voxel_chunks` table created by
  `DataService.Repo.Migrations.CreateVoxelChunks`. The composite identity is
  `(logical_scene_id, coord_x, coord_y, coord_z)`; Ecto needs each component
  marked `primary_key: true` so `Repo.get_by/2` and inserts work without a
  surrogate key.

  `chunk_hash` is a raw 8-byte u64 digest stored as `bytea` (protocol design
  §11). The changeset enforces the byte-length invariant so application code
  cannot quietly persist a different-sized hash.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  schema "voxel_chunks" do
    field(:logical_scene_id, :integer, primary_key: true)
    field(:coord_x, :integer, primary_key: true)
    field(:coord_y, :integer, primary_key: true)
    field(:coord_z, :integer, primary_key: true)
    field(:schema_version, :integer)
    field(:chunk_size_in_macro, :integer)
    field(:micro_resolution, :integer)
    field(:region_id, :integer)
    field(:lease_id, :integer)
    field(:owner_scene_instance_ref, :integer)
    field(:owner_epoch, :integer)
    field(:chunk_version, :integer)
    field(:chunk_hash, :binary)
    field(:data, :binary)

    timestamps()
  end

  @required_fields [
    :logical_scene_id,
    :coord_x,
    :coord_y,
    :coord_z,
    :schema_version,
    :chunk_size_in_macro,
    :micro_resolution,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :chunk_version,
    :chunk_hash,
    :data
  ]

  @nonneg_fields [
    :logical_scene_id,
    :schema_version,
    :chunk_size_in_macro,
    :micro_resolution,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :chunk_version
  ]

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_chunk_hash_length()
    |> validate_nonneg(@nonneg_fields)
  end

  defp validate_chunk_hash_length(changeset) do
    case get_field(changeset, :chunk_hash) do
      hash when is_binary(hash) and byte_size(hash) == 8 ->
        changeset

      _ ->
        add_error(changeset, :chunk_hash, "must be 8 bytes")
    end
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
end
