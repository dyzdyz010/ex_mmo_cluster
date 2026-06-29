defmodule DataService.Voxel.LodHeightmapStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Voxel.LodHeightmapStore, as: Store

  setup do
    Store.reset()
    :ok
  end

  test "upsert_cells and heightmap_region round-trip X-fastest u16 rows" do
    assert :ok =
             Store.upsert_cells([
               cell(-1, 2, 10, 101),
               cell(0, 2, 20, 102),
               cell(-1, 3, 30, 103),
               cell(0, 3, 40, 104)
             ])

    assert {:ok, %{heights: heights, materials: materials, meta: meta}} =
             Store.heightmap_region(1, -16, 32, 16, 2, 2)

    assert heights ==
             <<10::unsigned-big-integer-size(16), 20::unsigned-big-integer-size(16),
               30::unsigned-big-integer-size(16), 40::unsigned-big-integer-size(16)>>

    assert materials ==
             <<101::unsigned-big-integer-size(16), 102::unsigned-big-integer-size(16),
               103::unsigned-big-integer-size(16), 104::unsigned-big-integer-size(16)>>

    assert meta.source == :authoritative_lod_heightmap_store
    assert meta.missing_count == 0
    assert meta.decoded_cell_count == 4
  end

  test "upsert_cells replaces an existing projection cell" do
    assert :ok = Store.upsert_cells(cell(5, 6, 100, 9))
    assert :ok = Store.upsert_cells(cell(5, 6, 155, 42))

    assert {:ok,
            %{
              heights: <<155::unsigned-big-integer-size(16)>>,
              materials: <<42::unsigned-big-integer-size(16)>>
            }} =
             Store.heightmap_region(1, 80, 96, 16, 1, 1)
  end

  test "missing projection cells are explicit errors" do
    assert :ok = Store.upsert_cells(cell(0, 0, 1))

    assert {:error, {:missing_lod_heightmap_cells, meta}} =
             Store.heightmap_region(1, 0, 0, 16, 2, 1)

    assert meta.missing_count == 1
    assert [%{cell_x: 1, cell_z: 0, wx: 16, wz: 0}] = meta.missing_sample
  end

  test "heightmap reads require origin aligned to stride" do
    assert {:error, :unaligned_heightmap_region} =
             Store.heightmap_region(1, 1, 0, 16, 1, 1)
  end

  test "upsert_cells_in_repo participates in caller transaction rollback" do
    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert :ok = Store.upsert_cells_in_repo(Repo, cell(0, 0, 44))
               Repo.rollback(:rollback)
             end)

    assert {:error, {:missing_lod_heightmap_cells, _meta}} =
             Store.heightmap_region(1, 0, 0, 16, 1, 1)
  end

  test "invalid cells fail before insert" do
    assert {:error, :invalid_stride} = Store.upsert_cells(Map.put(cell(0, 0, 1), :stride, 0))
    assert {:error, :invalid_height} = Store.upsert_cells(Map.put(cell(0, 0, 1), :height, 65_536))

    assert {:error, :invalid_material_id} =
             Store.upsert_cells(Map.put(cell(0, 0, 1), :material_id, 65_536))
  end

  test "summary reports per-stride materialized projection coverage" do
    assert :ok =
             Store.upsert_cells([
               cell(-1, 2, 10),
               cell(0, 2, 20),
               cell(4, 8, 30) |> Map.put(:stride, 32)
             ])

    assert {:ok, summary} = Store.summary(1)

    assert summary.status == :ready
    assert summary.total_cell_count == 3

    assert [
             %{
               stride: 16,
               cell_count: 2,
               min_cell_x: -1,
               max_cell_x: 0,
               min_cell_z: 2,
               max_cell_z: 2,
               min_height: 10,
               max_height: 20,
               min_source_chunk_version: 7,
               max_source_chunk_version: 7
             },
             %{stride: 32, cell_count: 1, min_cell_x: 4, max_cell_x: 4}
           ] = summary.strides

    assert {:ok, filtered} = Store.summary(1, stride: 32)
    assert filtered.total_cell_count == 1
    assert [%{stride: 32}] = filtered.strides
  end

  test "summary reports empty and invalid filters explicitly" do
    assert {:ok, %{status: :empty, total_cell_count: 0, strides: []}} = Store.summary(1)
    assert {:error, :invalid_stride} = Store.summary(1, stride: 0)
    assert {:error, :invalid_logical_scene_id} = Store.summary(-1)
  end

  defp cell(cell_x, cell_z, height, material_id \\ 0) do
    %{
      logical_scene_id: 1,
      stride: 16,
      cell_x: cell_x,
      cell_z: cell_z,
      height: height,
      material_id: material_id,
      source_chunk_coord: {cell_x, 0, cell_z},
      source_chunk_version: 7
    }
  end
end
