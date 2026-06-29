defmodule SceneServer.Voxel.LodProjectionTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.LodProjection
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  test "builds stride projection cells from the changed storage" do
    storage =
      77
      |> Storage.empty({0, 0, 0})
      |> Storage.put_solid_block({0, 0, 0}, NormalBlockData.new(1))
      |> Storage.put_solid_block({1, 4, 0}, NormalBlockData.new(2))

    assert {:ok, cells} =
             LodProjection.cells_for_storage(storage, strides: [2], snapshot_index: %{})

    assert length(cells) == 64

    assert %{height: 5, material_id: 2, source_chunk_coord: {0, 0, 0}} =
             find_cell(cells, 2, 0, 0)

    assert %{height: 0, material_id: 0} = find_cell(cells, 2, 1, 0)
  end

  test "uses persisted vertical column snapshots when computing column top" do
    lower =
      77
      |> Storage.empty({0, 0, 0})
      |> Storage.put_solid_block({0, 0, 0}, NormalBlockData.new(1))

    upper =
      77
      |> Storage.empty({0, 1, 0})
      |> Storage.put_solid_block({0, 2, 0}, NormalBlockData.new(9))

    snapshot_index = %{{77, {0, 1, 0}} => %{storage: upper}}

    assert {:ok, cells} =
             LodProjection.cells_for_storage(lower, strides: [16], snapshot_index: snapshot_index)

    assert [%{stride: 16, cell_x: 0, cell_z: 0, height: 19, material_id: 9}] = cells
  end

  test "uses the highest occupied refined micro layer as projection material" do
    storage =
      77
      |> Storage.empty({0, 0, 0})
      |> Storage.put_micro_block({0, 0, 0}, 0, %{material_id: 7})
      |> Storage.put_micro_block({0, 0, 0}, micro_slot(0, 7, 0), %{material_id: 42})

    assert {:ok, cells} =
             LodProjection.cells_for_storage(storage, strides: [16], snapshot_index: %{})

    assert [%{height: 1, material_id: 42}] = cells
  end

  test "rejects unsupported projection strides" do
    storage = Storage.empty(77, {0, 0, 0})

    assert {:error, :invalid_lod_projection_strides} =
             LodProjection.cells_for_storage(storage, strides: [3], snapshot_index: %{})
  end

  defp find_cell(cells, stride, cell_x, cell_z) do
    Enum.find(cells, fn cell ->
      cell.stride == stride and cell.cell_x == cell_x and cell.cell_z == cell_z
    end)
  end

  defp micro_slot(x, y, z), do: x + y * 8 + z * 64
end
