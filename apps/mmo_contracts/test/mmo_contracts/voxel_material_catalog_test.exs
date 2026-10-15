defmodule MmoContracts.VoxelMaterialCatalogTest do
  use ExUnit.Case, async: true

  alias MmoContracts.VoxelMaterialCatalog

  @table Enum.with_index(
           ~w(air grass dry_grass moss snow sand gravel dirt clay sandstone limestone stone granite basalt marble coal_ore copper_ore iron_ore gold_ore wood ice water lava glowstone copper
              birch_wood maple_wood spruce_wood oak_leaves birch_leaves maple_leaves spruce_leaves short_grass tall_grass fern poppy dandelion cornflower daisy allium resistive_alloy switch energy_stone thermoelectric_stone glass thermistor_ceramic masonry dressed_stone roof_tile timber_boards stained_glass gilded_stone fired_clay_roof_tile imperial_floor_brick famille_rose_porcelain fired_clay_wall_brick taihu_stone)
         )
         |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name} end)

  test "Voxim 契约保留完整且有序的 0..56 材质语义" do
    assert VoxelMaterialCatalog.table() == @table
    assert Enum.map(@table, & &1["id"]) == Enum.to_list(0..56)
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
    assert VoxelMaterialCatalog.valid_id?(44)
    assert VoxelMaterialCatalog.valid_id?(45)
    assert VoxelMaterialCatalog.valid_id?(51)
    assert VoxelMaterialCatalog.valid_id?(55)
    assert VoxelMaterialCatalog.valid_id?(56)
    refute VoxelMaterialCatalog.valid_id?(57)
    refute VoxelMaterialCatalog.valid_id?(255)
  end

  # R8-08：玻璃与冰、水一样透明，客户端区域解码拒绝透明材料的附件，所以服务端也不许用它做面／线附件。
  test "透明材料（冰、水、玻璃）与空气不能做附件，其余实体材料可以" do
    refute Enum.any?([0, 20, 21, 44, 50], &MmoContracts.Voxel.Attachments.material?/1)
    # R8-10：温敏陶瓷 45 不透明，可做面／线附件（温敏面直接嵌进导线）。
    assert Enum.all?([5, 11, 22, 24, 43, 45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56], &MmoContracts.Voxel.Attachments.material?/1)
  end

  test "identity bytes 是紧凑有序 pair JSON，而非 map 枚举结果" do
    expected =
      "[[0,\"air\"],[1,\"grass\"],[2,\"dry_grass\"],[3,\"moss\"],[4,\"snow\"],[5,\"sand\"],[6,\"gravel\"],[7,\"dirt\"],[8,\"clay\"],[9,\"sandstone\"],[10,\"limestone\"],[11,\"stone\"],[12,\"granite\"],[13,\"basalt\"],[14,\"marble\"],[15,\"coal_ore\"],[16,\"copper_ore\"],[17,\"iron_ore\"],[18,\"gold_ore\"],[19,\"wood\"],[20,\"ice\"],[21,\"water\"],[22,\"lava\"],[23,\"glowstone\"],[24,\"copper\"],[25,\"birch_wood\"],[26,\"maple_wood\"],[27,\"spruce_wood\"],[28,\"oak_leaves\"],[29,\"birch_leaves\"],[30,\"maple_leaves\"],[31,\"spruce_leaves\"],[32,\"short_grass\"],[33,\"tall_grass\"],[34,\"fern\"],[35,\"poppy\"],[36,\"dandelion\"],[37,\"cornflower\"],[38,\"daisy\"],[39,\"allium\"],[40,\"resistive_alloy\"],[41,\"switch\"],[42,\"energy_stone\"],[43,\"thermoelectric_stone\"],[44,\"glass\"],[45,\"thermistor_ceramic\"],[46,\"masonry\"],[47,\"dressed_stone\"],[48,\"roof_tile\"],[49,\"timber_boards\"],[50,\"stained_glass\"],[51,\"gilded_stone\"],[52,\"fired_clay_roof_tile\"],[53,\"imperial_floor_brick\"],[54,\"famille_rose_porcelain\"],[55,\"fired_clay_wall_brick\"],[56,\"taihu_stone\"]]"

    assert VoxelMaterialCatalog.identity_bytes() == expected
    assert byte_size(expected) == 972
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

    expected = <<"voxim-blocking-v1\n", 57::16-big, records::binary>>
    assert VoxelMaterialCatalog.blocking_bytes() == expected
    assert VoxelMaterialCatalog.blocking_hash() == :crypto.hash(:sha256, expected)
    # 57 项（追加太湖石56）；冻结值由 Python struct/hashlib 从契约 JSON 独立复算。
    assert Base.encode16(VoxelMaterialCatalog.blocking_hash(), case: :lower) ==
             "efcbc12e4a2e95c7644f8113853f66c7542a99eb0faa815ea63398946a6ed004"

    IO.puts(
      "W1_MATERIAL " <>
        Jason.encode!(%{
          blocking_bytes_hex: Base.encode16(expected, case: :lower),
          blocking_hash: Base.encode16(VoxelMaterialCatalog.blocking_hash(), case: :lower)
        })
    )
  end
end
