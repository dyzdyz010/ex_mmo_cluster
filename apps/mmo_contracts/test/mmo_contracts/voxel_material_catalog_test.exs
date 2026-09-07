defmodule MmoContracts.VoxelMaterialCatalogTest do
  use ExUnit.Case, async: true

  alias MmoContracts.VoxelMaterialCatalog

  @table Enum.with_index(
           ~w(air grass dry_grass moss snow sand gravel dirt clay sandstone limestone stone granite basalt marble coal_ore copper_ore iron_ore gold_ore wood ice water lava glowstone)
         )
         |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name} end)

  test "Voxim 契约保留完整且有序的 0..23 材质语义" do
    assert VoxelMaterialCatalog.table() == @table
    assert Enum.map(@table, & &1["id"]) == Enum.to_list(0..23)
    assert Enum.uniq_by(@table, & &1["name"]) == @table
    assert VoxelMaterialCatalog.valid_id?(0)
    assert VoxelMaterialCatalog.valid_id?(2)
    assert VoxelMaterialCatalog.valid_id?(23)
    refute VoxelMaterialCatalog.valid_id?(24)
    refute VoxelMaterialCatalog.valid_id?(255)
  end

  test "identity bytes 是紧凑有序 pair JSON，而非 map 枚举结果" do
    expected =
      "[[0,\"air\"],[1,\"grass\"],[2,\"dry_grass\"],[3,\"moss\"],[4,\"snow\"],[5,\"sand\"],[6,\"gravel\"],[7,\"dirt\"],[8,\"clay\"],[9,\"sandstone\"],[10,\"limestone\"],[11,\"stone\"],[12,\"granite\"],[13,\"basalt\"],[14,\"marble\"],[15,\"coal_ore\"],[16,\"copper_ore\"],[17,\"iron_ore\"],[18,\"gold_ore\"],[19,\"wood\"],[20,\"ice\"],[21,\"water\"],[22,\"lava\"],[23,\"glowstone\"]]"

    assert VoxelMaterialCatalog.identity_bytes() == expected
    assert byte_size(expected) == 327
  end
end
