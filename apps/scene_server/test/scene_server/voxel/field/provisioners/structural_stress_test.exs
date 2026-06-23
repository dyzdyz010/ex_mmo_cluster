defmodule SceneServer.Voxel.Field.Provisioners.StructuralStressTest do
  @moduledoc """
  力学应力 provisioner 纯 detect 单测:有失支撑 → active(起 [structural_stress] region);
  全坐地/连地 → inactive;无 storage → inactive。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.{NormalBlockData, Storage}
  alias SceneServer.Voxel.Field.Kernels.StructuralStressKernel
  alias SceneServer.Voxel.Field.Provisioners.StructuralStress

  @stone 2

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp ctx(storage), do: %{storage: storage, chunk_coord: {0, 0, 0}, logical_scene_id: 1}

  test "source_key 稳定且各 chunk 互异" do
    assert StructuralStress.source_key(%{logical_scene_id: 1, chunk_coord: {0, 0, 0}}) ==
             {:structural_stress, 1, {0, 0, 0}}

    refute StructuralStress.source_key(%{logical_scene_id: 1, chunk_coord: {0, 0, 0}}) ==
             StructuralStress.source_key(%{logical_scene_id: 1, chunk_coord: {1, 0, 0}})
  end

  test "坐地塔:无失支撑 → inactive" do
    storage =
      Storage.new(1, {0, 0, 0})
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({0, 1, 0}, @stone)

    assert {:inactive, :no_unsupported_structure, %{unsupported_count: 0}} =
             StructuralStress.detect(ctx(storage))
  end

  test "悬空结构:有失支撑 → active 起 [structural_stress] region(AABB 含地锚 y=0)" do
    storage =
      Storage.new(1, {0, 0, 0})
      |> put_solid({0, 0, 0}, @stone)
      |> put_solid({5, 5, 5}, @stone)
      |> put_solid({5, 6, 5}, @stone)

    assert {:active, attrs, %{unsupported_count: 2}} = StructuralStress.detect(ctx(storage))
    assert attrs.aabb == {{0, 0, 0}, {15, 15, 15}}
    assert [%{id: :structural_stress, module: StructuralStressKernel}] = attrs.kernels
  end

  test "无 storage → inactive" do
    assert {:inactive, :no_storage, _} = StructuralStress.detect(%{chunk_coord: {0, 0, 0}})
  end

  test "unsupported_structure? 谓词:悬空 true、坐地 false" do
    floating = put_solid(Storage.new(1, {0, 0, 0}), {3, 7, 3}, @stone)
    grounded = put_solid(Storage.new(1, {0, 0, 0}), {3, 0, 3}, @stone)

    assert StructuralStress.unsupported_structure?(floating)
    refute StructuralStress.unsupported_structure?(grounded)
  end
end
