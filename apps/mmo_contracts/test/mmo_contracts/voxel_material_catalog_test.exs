defmodule MmoContracts.VoxelMaterialCatalogTest do
  use ExUnit.Case, async: true

  alias MmoContracts.VoxelMaterialCatalog

  test "荷花与荷叶不阻挡移动，仍可支撑附件；旧材料资格保持" do
    for id <- [65, 73] do
      refute VoxelMaterialCatalog.blocks_movement?(id)
      assert VoxelMaterialCatalog.supports_attachments?(id)
    end
    for id <- 0..73, id not in [65, 73] do
      assert VoxelMaterialCatalog.supports_attachments?(id) ==
               VoxelMaterialCatalog.blocks_movement?(id)
    end
    refute VoxelMaterialCatalog.blocks_movement?(35)
    refute VoxelMaterialCatalog.supports_attachments?(35)
    assert Enum.all?([3, 66, 67, 68, 69, 70], &VoxelMaterialCatalog.blocks_movement?/1)
  end

  @table Enum.with_index(
           ~w(air grass dry_grass moss snow sand gravel dirt clay sandstone limestone stone granite basalt marble coal_ore copper_ore iron_ore gold_ore wood ice water lava glowstone copper
              birch_wood maple_wood spruce_wood oak_leaves birch_leaves maple_leaves spruce_leaves short_grass tall_grass fern poppy dandelion cornflower daisy allium resistive_alloy switch energy_stone thermoelectric_stone glass thermistor_ceramic masonry dressed_stone roof_tile timber_boards stained_glass gilded_stone fired_clay_roof_tile imperial_floor_brick famille_rose_porcelain fired_clay_wall_brick taihu_stone)
         )
         |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name} end)

  @plants Enum.with_index(~w(willow_wood willow_leaves pine_wood pine_leaves bamboo_culm bamboo_leaves peach_wood peach_leaves lotus potted_plum potted_peony potted_chrysanthemum potted_orchid terracotta_pot climbing_vine rock_moss lotus_leaves), 57)
          |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name} end)

  @finishes Enum.with_index(~w(silk_gauze lined_canopy_cloth red_lacquer_wood tiger_skin_masonry gray_floor_brick pebble_paving qingbai_stone rammed_lime_earth pond_mud blue_gray_plaster green_oiled_wood natural_oiled_wood suzhou_painted_wood korean_window_paper), 74)
            |> Enum.map(fn {name, id} -> %{"id" => id, "name" => name} end)

  test "Voxim 保留旧材料身份并追加正式建筑材料至87" do
    assert Enum.take(VoxelMaterialCatalog.table(), 57) == @table
    assert VoxelMaterialCatalog.table() == @table ++ @plants ++ @finishes
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
    assert VoxelMaterialCatalog.valid_id?(57)
    assert VoxelMaterialCatalog.valid_id?(73)
    assert VoxelMaterialCatalog.valid_id?(74)
    for id <- 75..87 do
      assert VoxelMaterialCatalog.valid_id?(id)
      assert VoxelMaterialCatalog.blocks_movement?(id)
      assert VoxelMaterialCatalog.supports_attachments?(id)
    end
    refute VoxelMaterialCatalog.valid_id?(88)
    assert VoxelMaterialCatalog.blocks_movement?(74)
    assert VoxelMaterialCatalog.supports_attachments?(74)
    refute VoxelMaterialCatalog.valid_id?(255)
  end

  # R8-08：玻璃与冰、水一样透明，客户端区域解码拒绝透明材料的附件，所以服务端也不许用它做面／线附件。
  test "透明材料（冰、水、玻璃）与空气不能做附件，其余实体材料可以" do
    refute Enum.any?([0, 20, 21, 44, 50, 74, 87], &MmoContracts.Voxel.Attachments.material?/1)
    # R8-10：温敏陶瓷 45 不透明，可做面／线附件（温敏面直接嵌进导线）。
    assert Enum.all?([5, 11, 22, 24, 43, 45, 46, 47, 48, 49, 51, 52, 53, 54, 55, 56], &MmoContracts.Voxel.Attachments.material?/1)
    assert Enum.all?(65..73, &MmoContracts.Voxel.Attachments.material?/1)
    assert Enum.all?(75..86, &MmoContracts.Voxel.Attachments.material?/1)
    # 附件材质资格与支撑格的移动碰撞是不同规则；旧、新叶片均允许作为不透明覆层。
    assert Enum.all?([28, 58, 60, 62, 64], &MmoContracts.Voxel.Attachments.material?/1)
  end

  test "identity bytes 是紧凑有序 pair JSON，而非 map 枚举结果" do
    expected =
      "[[0,\"air\"],[1,\"grass\"],[2,\"dry_grass\"],[3,\"moss\"],[4,\"snow\"],[5,\"sand\"],[6,\"gravel\"],[7,\"dirt\"],[8,\"clay\"],[9,\"sandstone\"],[10,\"limestone\"],[11,\"stone\"],[12,\"granite\"],[13,\"basalt\"],[14,\"marble\"],[15,\"coal_ore\"],[16,\"copper_ore\"],[17,\"iron_ore\"],[18,\"gold_ore\"],[19,\"wood\"],[20,\"ice\"],[21,\"water\"],[22,\"lava\"],[23,\"glowstone\"],[24,\"copper\"],[25,\"birch_wood\"],[26,\"maple_wood\"],[27,\"spruce_wood\"],[28,\"oak_leaves\"],[29,\"birch_leaves\"],[30,\"maple_leaves\"],[31,\"spruce_leaves\"],[32,\"short_grass\"],[33,\"tall_grass\"],[34,\"fern\"],[35,\"poppy\"],[36,\"dandelion\"],[37,\"cornflower\"],[38,\"daisy\"],[39,\"allium\"],[40,\"resistive_alloy\"],[41,\"switch\"],[42,\"energy_stone\"],[43,\"thermoelectric_stone\"],[44,\"glass\"],[45,\"thermistor_ceramic\"],[46,\"masonry\"],[47,\"dressed_stone\"],[48,\"roof_tile\"],[49,\"timber_boards\"],[50,\"stained_glass\"],[51,\"gilded_stone\"],[52,\"fired_clay_roof_tile\"],[53,\"imperial_floor_brick\"],[54,\"famille_rose_porcelain\"],[55,\"fired_clay_wall_brick\"],[56,\"taihu_stone\"]]"

    assert byte_size(expected) == 972
    plants = ",[[57,\"willow_wood\"],[58,\"willow_leaves\"],[59,\"pine_wood\"],[60,\"pine_leaves\"],[61,\"bamboo_culm\"],[62,\"bamboo_leaves\"],[63,\"peach_wood\"],[64,\"peach_leaves\"],[65,\"lotus\"],[66,\"potted_plum\"],[67,\"potted_peony\"],[68,\"potted_chrysanthemum\"],[69,\"potted_orchid\"],[70,\"terracotta_pot\"],[71,\"climbing_vine\"],[72,\"rock_moss\"],[73,\"lotus_leaves\"]]"
    old_identity = binary_part(expected, 0, byte_size(expected) - 1) <> String.replace_prefix(plants, ",[[", ",[")
    assert VoxelMaterialCatalog.identity_bytes() == binary_part(old_identity, 0, byte_size(old_identity)-1) <> ",[74,\"silk_gauze\"],[75,\"lined_canopy_cloth\"],[76,\"red_lacquer_wood\"],[77,\"tiger_skin_masonry\"],[78,\"gray_floor_brick\"],[79,\"pebble_paving\"],[80,\"qingbai_stone\"],[81,\"rammed_lime_earth\"],[82,\"pond_mud\"],[83,\"blue_gray_plaster\"],[84,\"green_oiled_wood\"],[85,\"natural_oiled_wood\"],[86,\"suzhou_painted_wood\"],[87,\"korean_window_paper\"]]"
  end

  # 2026-09-21 契约：树叶与地面花草是非实体格——可选中、可攻击，但不挡移动。
  @passable ~w(air water oak_leaves birch_leaves maple_leaves spruce_leaves short_grass tall_grass fern poppy dandelion cornflower daisy allium willow_leaves pine_leaves bamboo_leaves peach_leaves)

  test "blocking metadata has independent canonical bytes and never changes material identity" do
    for %{"id" => id, "name" => name} <- @table ++ @plants do
      assert VoxelMaterialCatalog.blocks_movement?(id) == name not in (@passable ++ ~w(lotus lotus_leaves))
    end

    records =
      for %{"id" => id, "name" => name} <- @table ++ @plants, into: <<>> do
        <<id::16-big, if(name in (@passable ++ ~w(lotus lotus_leaves)), do: 0, else: 1),
          if(name in @passable, do: 0, else: 1)>>
      end

    finishes = for id <- 74..87, into: <<>>, do: <<id::16-big, 1, 1>>
    expected = <<"voxim-blocking-v2\n", 88::16-big, records::binary, finishes::binary>>
    assert VoxelMaterialCatalog.blocking_bytes() == expected
    assert VoxelMaterialCatalog.blocking_hash() == :crypto.hash(:sha256, expected)
    # 88项；MAT2a三种木材及封闭纸窗均阻挡/支撑，冻结值由Python struct/hashlib独立复算。
    assert Base.encode16(VoxelMaterialCatalog.blocking_hash(), case: :lower) ==
             "d63d153b4f7779f89133c0710a4151e55953d35c99ac6341302fceac61b4211e"

    IO.puts(
      "W1_MATERIAL " <>
        Jason.encode!(%{
          blocking_bytes_hex: Base.encode16(expected, case: :lower),
          blocking_hash: Base.encode16(VoxelMaterialCatalog.blocking_hash(), case: :lower)
        })
    )
  end
end
