defmodule MmoContracts.VoxelMaterialCatalogTest do
  use ExUnit.Case, async: true

  alias MmoContracts.VoxelMaterialCatalog

  @table Enum.with_index(
           ~w(air grass dry_grass moss snow sand gravel dirt clay sandstone limestone stone granite basalt marble coal_ore copper_ore iron_ore gold_ore wood ice water lava glowstone copper
              birch_wood maple_wood spruce_wood oak_leaves birch_leaves maple_leaves spruce_leaves short_grass tall_grass fern poppy dandelion cornflower daisy allium resistive_alloy switch energy_stone thermoelectric_stone)
         )
         |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name} end)

  test "Voxim 契约保留完整且有序的 0..43 材质语义" do
    assert VoxelMaterialCatalog.table() == @table
    assert Enum.map(@table, & &1["id"]) == Enum.to_list(0..43)
    assert Enum.uniq_by(@table, & &1["name"]) == @table
    assert VoxelMaterialCatalog.valid_id?(0)
    assert VoxelMaterialCatalog.valid_id?(2)
    assert VoxelMaterialCatalog.valid_id?(23)
    assert VoxelMaterialCatalog.valid_id?(24)
    assert VoxelMaterialCatalog.valid_id?(39)
    assert VoxelMaterialCatalog.valid_id?(40)
    assert VoxelMaterialCatalog.valid_id?(41)
    assert VoxelMaterialCatalog.valid_id?(42)
    assert VoxelMaterialCatalog.valid_id?(43)
    refute VoxelMaterialCatalog.valid_id?(44)
    refute VoxelMaterialCatalog.valid_id?(255)
  end

  test "identity bytes 是紧凑有序 pair JSON，而非 map 枚举结果" do
    expected =
      "[[0,\"air\"],[1,\"grass\"],[2,\"dry_grass\"],[3,\"moss\"],[4,\"snow\"],[5,\"sand\"],[6,\"gravel\"],[7,\"dirt\"],[8,\"clay\"],[9,\"sandstone\"],[10,\"limestone\"],[11,\"stone\"],[12,\"granite\"],[13,\"basalt\"],[14,\"marble\"],[15,\"coal_ore\"],[16,\"copper_ore\"],[17,\"iron_ore\"],[18,\"gold_ore\"],[19,\"wood\"],[20,\"ice\"],[21,\"water\"],[22,\"lava\"],[23,\"glowstone\"],[24,\"copper\"],[25,\"birch_wood\"],[26,\"maple_wood\"],[27,\"spruce_wood\"],[28,\"oak_leaves\"],[29,\"birch_leaves\"],[30,\"maple_leaves\"],[31,\"spruce_leaves\"],[32,\"short_grass\"],[33,\"tall_grass\"],[34,\"fern\"],[35,\"poppy\"],[36,\"dandelion\"],[37,\"cornflower\"],[38,\"daisy\"],[39,\"allium\"],[40,\"resistive_alloy\"],[41,\"switch\"],[42,\"energy_stone\"],[43,\"thermoelectric_stone\"]]"

    assert VoxelMaterialCatalog.identity_bytes() == expected
    assert byte_size(expected) == 684
  end

  # 2026-09-21 契约：树叶与地面花草是非实体格——可选中、可攻击，但不挡移动。
  @passable ~w(air water oak_leaves birch_leaves maple_leaves spruce_leaves short_grass tall_grass fern poppy dandelion cornflower daisy allium)

  test "blocking metadata has independent canonical bytes and never changes material identity" do
    for %{"id" => id, "name" => name} <- @table do
      assert VoxelMaterialCatalog.blocks_movement?(id) == name not in @passable
    end

    records =
      for %{"id" => id, "name" => name} <- @table, into: <<>> do
        <<id::16-big, if(name in @passable, do: 0, else: 1)>>
      end

    expected = <<"voxim-blocking-v1\n", 44::16-big, records::binary>>
    assert VoxelMaterialCatalog.blocking_bytes() == expected
    assert VoxelMaterialCatalog.blocking_hash() == :crypto.hash(:sha256, expected)

    IO.puts(
      "W1_MATERIAL " <>
        Jason.encode!(%{
          blocking_bytes_hex: Base.encode16(expected, case: :lower),
          blocking_hash: Base.encode16(VoxelMaterialCatalog.blocking_hash(), case: :lower)
        })
    )
  end
end
