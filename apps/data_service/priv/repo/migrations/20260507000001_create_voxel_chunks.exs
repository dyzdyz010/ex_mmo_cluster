defmodule DataService.Repo.Migrations.CreateVoxelChunks do
  use Ecto.Migration

  @moduledoc """
  Canonical persistence for `DataService.Voxel.ChunkSnapshotStore`.

  Layout matches `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` §11.
  Hot-queryable fields are stored as their own columns; the full chunk truth
  (`Storage` serialized via `SceneServer.Voxel.Codec.encode_chunk_snapshot_payload/1`)
  goes into `data bytea`. `chunk_hash` is the raw 8-byte u64 digest (kept as
  `bytea` per protocol spec rather than `bigint`, since the high bit can be
  set and `bigint` is signed).

  Composite primary key `(logical_scene_id, coord_x, coord_y, coord_z)` is the
  natural identity. All `bigint` fields constrain `>= 0` to match the v1
  protocol restriction (u63).
  """

  def change do
    create table(:voxel_chunks, primary_key: false) do
      add(:logical_scene_id, :bigint, null: false)
      add(:coord_x, :integer, null: false)
      add(:coord_y, :integer, null: false)
      add(:coord_z, :integer, null: false)
      add(:schema_version, :smallint, null: false)
      add(:chunk_size_in_macro, :smallint, null: false)
      add(:micro_resolution, :smallint, null: false)
      add(:region_id, :bigint, null: false)
      add(:lease_id, :bigint, null: false)
      add(:owner_scene_instance_ref, :bigint, null: false)
      add(:owner_epoch, :bigint, null: false)
      add(:chunk_version, :bigint, null: false)
      add(:chunk_hash, :binary, null: false)
      add(:data, :binary, null: false)

      timestamps()
    end

    execute(
      """
      ALTER TABLE voxel_chunks
        ADD CONSTRAINT voxel_chunks_pkey
        PRIMARY KEY (logical_scene_id, coord_x, coord_y, coord_z)
      """,
      "ALTER TABLE voxel_chunks DROP CONSTRAINT voxel_chunks_pkey"
    )

    for {field, name} <- [
          {"logical_scene_id", "voxel_chunks_logical_scene_id_nonneg"},
          {"schema_version", "voxel_chunks_schema_version_nonneg"},
          {"chunk_size_in_macro", "voxel_chunks_chunk_size_in_macro_nonneg"},
          {"micro_resolution", "voxel_chunks_micro_resolution_nonneg"},
          {"region_id", "voxel_chunks_region_id_nonneg"},
          {"lease_id", "voxel_chunks_lease_id_nonneg"},
          {"owner_scene_instance_ref", "voxel_chunks_owner_scene_instance_ref_nonneg"},
          {"owner_epoch", "voxel_chunks_owner_epoch_nonneg"},
          {"chunk_version", "voxel_chunks_chunk_version_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_chunks ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_chunks DROP CONSTRAINT #{name}"
      )
    end

    execute(
      "ALTER TABLE voxel_chunks ADD CONSTRAINT voxel_chunks_chunk_hash_8_bytes " <>
        "CHECK (octet_length(chunk_hash) = 8)",
      "ALTER TABLE voxel_chunks DROP CONSTRAINT voxel_chunks_chunk_hash_8_bytes"
    )
  end
end
