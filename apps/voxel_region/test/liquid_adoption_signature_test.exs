defmodule VoxelRegion.LiquidAdoptionSignatureTest do
  @moduledoc "只测试：合法不可变地形的纯 owner 回调；26 邻区不应使派生备忘常驻展开 ring 或大父二进制。"
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{Cache, Liquids, Payloads}
  alias MmoContracts.Voxel.{Payload, Skins}

  test "26个邻区的干地形检查只保留固定内容指纹" do
    bytes = 66 * 66 * 66 * 2
    parent = :binary.copy(<<0>>, bytes * 2)
    cells = binary_part(parent, 0, bytes)
    bases = for x <- -1..1, y <- -1..1, z <- -1..1, into: %{},
      do: {{0, {x,y,z}}, %Payload{level: 0, region: {x,y,z}, cells: cells}}
    state = %{region_bases: bases, overlay_regions: %{}, overlay: %{}, decoded: %{}, cache: Cache.new(0), snapshots: MapSet.new(Map.keys(bases)),
      liquid_bounds: {{-1,-1,-1},{65,65,65}}, liquid_units: %{}, liquid_adopted: %{}}
    assert {:ok, _, overrides, _} = Payloads.terrain_materials(state, 0, {0,0,0})
    assert map_size(overrides) == 0
    checked = Liquids.adopt_liquid_sources(state, {0,0,0})
    memo = Map.fetch!(checked.liquid_adopted, {0,0,0})
    IO.inspect(%{ring_entries: map_size(overrides), memo_words: :erts_debug.flat_size(memo)},
      label: "LIQUID_ADOPTION_MEMO")
    assert is_binary(memo)
    assert byte_size(memo) == 32
    assert :binary.referenced_byte_size(memo) == 32
    assert Liquids.adopt_liquid_sources(checked, {0,0,0}).liquid_adopted == checked.liquid_adopted
    # 已有合法数量的液体只改变地形身份，不需重复提交；内容变更不能复用旧干区指纹。
    water = {0,0,0}
    changed = %{checked | overlay: %{{0, water} => {21, Skins.uniform(21)}},
      overlay_regions: %{{0, {0,0,0}} => MapSet.new([water])}, liquid_units: %{water => 2_097_152}}
    next = Liquids.adopt_liquid_sources(changed, {0,0,0})
    refute next.liquid_adopted[{0,0,0}] == memo
    assert byte_size(next.liquid_adopted[{0,0,0}]) == 32
    assert next.liquid_units == changed.liquid_units
  end
end
