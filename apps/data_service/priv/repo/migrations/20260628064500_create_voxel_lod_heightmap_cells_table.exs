defmodule DataService.Repo.Migrations.CreateVoxelLodHeightmapCellsTable do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS voxel_lod_heightmap_cells (
      logical_scene_id bigint NOT NULL,
      stride integer NOT NULL,
      cell_x bigint NOT NULL,
      cell_z bigint NOT NULL,
      height integer NOT NULL,
      material_id integer NOT NULL DEFAULT 0,
      source_chunk_x integer NULL,
      source_chunk_y integer NULL,
      source_chunk_z integer NULL,
      source_chunk_version bigint NULL,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    add_constraint_if_missing(
      "voxel_lod_heightmap_cells_pkey",
      "PRIMARY KEY (logical_scene_id, stride, cell_x, cell_z)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS voxel_lod_heightmap_cells_logical_scene_id_stride_index " <>
        "ON voxel_lod_heightmap_cells (logical_scene_id, stride)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS voxel_lod_heightmap_cells_source_chunk_idx " <>
        "ON voxel_lod_heightmap_cells (logical_scene_id, source_chunk_x, source_chunk_y, source_chunk_z)"
    )

    for {field, name, comparator} <- [
          {"logical_scene_id", "voxel_lod_heightmap_cells_logical_scene_id_nonneg", ">= 0"},
          {"stride", "voxel_lod_heightmap_cells_stride_positive", "> 0"},
          {"height", "voxel_lod_heightmap_cells_height_u16", ">= 0 AND height <= 65535"},
          {"material_id", "voxel_lod_heightmap_cells_material_id_nonneg", ">= 0"},
          {"source_chunk_version", "voxel_lod_heightmap_cells_source_chunk_version_nonneg",
           "IS NULL OR source_chunk_version >= 0"}
        ] do
      add_constraint_if_missing(name, "CHECK (#{field} #{comparator})")
    end
  end

  def down do
    drop_if_exists(table(:voxel_lod_heightmap_cells))
  end

  defp add_constraint_if_missing(name, definition) do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conname = '#{name}'
           AND conrelid = 'voxel_lod_heightmap_cells'::regclass
      ) THEN
        ALTER TABLE voxel_lod_heightmap_cells ADD CONSTRAINT #{name} #{definition};
      END IF;
    END $$;
    """)
  end
end
