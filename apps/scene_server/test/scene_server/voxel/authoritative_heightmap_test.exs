defmodule SceneServer.Voxel.AuthoritativeHeightmapTest do
  use ExUnit.Case, async: false

  alias DataService.Voxel.LodHeightmapStore
  alias SceneServer.Voxel.AuthoritativeHeightmap
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  setup do
    LodHeightmapStore.reset()
    :ok
  end

  test "reads u16 heights from the persistent LOD projection by default" do
    assert :ok =
             LodHeightmapStore.upsert_cells([
               lod_cell(0, 0, 7, 101),
               lod_cell(1, 0, 11, 102)
             ])

    assert {:ok, %{heights: heights, materials: materials, meta: meta}} =
             AuthoritativeHeightmap.heightmap_region(77, 0, 0, 16, 2, 1)

    assert <<7::16-big, 11::16-big>> = heights
    assert <<101::16-big, 102::16-big>> = materials
    assert meta.source == :authoritative_lod_heightmap_store
  end

  test "derives u16 heights from persisted authoritative chunk snapshots when explicitly requested" do
    scene_id = 77

    lower =
      scene_id
      |> Storage.empty({0, 0, 0})
      |> Storage.put_solid_block({0, 0, 0}, NormalBlockData.new(1))
      |> Storage.put_solid_block({1, 4, 0}, NormalBlockData.new(2))

    upper =
      scene_id
      |> Storage.empty({0, 1, 0})
      |> Storage.put_solid_block({0, 2, 0}, NormalBlockData.new(2))

    snapshot_index = %{
      {scene_id, {0, 0, 0}} => %{data: Codec.encode_chunk_snapshot_payload(lower)},
      {scene_id, {0, 1, 0}} => %{data: Codec.encode_chunk_snapshot_payload(upper)}
    }

    assert {:ok, %{heights: heights, materials: materials, meta: meta}} =
             AuthoritativeHeightmap.heightmap_region(scene_id, 0, 0, 1, 2, 1,
               snapshot_index: snapshot_index
             )

    assert <<19::16-big, 5::16-big>> = heights
    assert <<2::16-big, 2::16-big>> = materials
    assert meta.source == :authoritative_chunk_snapshot_store
    assert meta.decoded_chunk_count == 2
    assert meta.decoded_column_count == 1
  end

  test "refuses to synthesize missing columns from WorldGen noise" do
    assert {:error, {:missing_authoritative_columns, meta}} =
             AuthoritativeHeightmap.heightmap_region(88, 0, 0, 16, 2, 1, snapshot_index: %{})

    assert meta.logical_scene_id == 88
    assert meta.missing_count == 2
    assert [%{wx: 0, wz: 0}, %{wx: 16, wz: 0}] = meta.missing_sample
  end

  defp lod_cell(cell_x, cell_z, height, material_id) do
    %{
      logical_scene_id: 77,
      stride: 16,
      cell_x: cell_x,
      cell_z: cell_z,
      height: height,
      material_id: material_id
    }
  end
end
