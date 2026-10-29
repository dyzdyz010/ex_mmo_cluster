defmodule VoxelRegion.RefinedCompactTest do
  @moduledoc """
  只测试：每宏格紧凑槽值的构造、完整字段、旧枚举次序与有序编码投影。

  纯算法层经 Canonical 的真实写入口产生槽值，不启动 World、数据库或网络。
  输入来自小型合法槽集合；期望来自原 map 的既有次序及手算坐标、身份和边界。
  旧实现必须首先在 typed 值断言失败，不能用缺失函数异常代替首红。
  """
  use ExUnit.Case, async: true

  alias VoxelRegion.World.{Canonical, Observation}
  alias VoxelRegion.RefinedSlots

  defp empty do
    %{refined: %{}, refined_owners: %{}, refined_regions: %{}}
  end

  test "canonical 接纳后只保存独立宏格紧凑值，保留完整字段与原枚举次序" do
    assert RefinedSlots.sorted_records(RefinedSlots.empty()) == <<>>
    for count <- [1, 32, 33, 512] do
      input = Map.new(0..(count - 1), fn slot ->
        {slot, {11 + rem(slot, 2), {18_446_744_073_709_551_615, 4_294_967_295}}}
      end)
      cell = {-1, 64, 129}
      state = Canonical.put_refined(empty(), cell, input)
      value = Map.fetch!(state.refined, cell)

      assert is_struct(value, RefinedSlots)
      assert RefinedSlots.size(value) == count
      assert RefinedSlots.reduce(value, [], fn row, rows -> [row | rows] end)
             |> Enum.reverse() == Enum.to_list(input)
      assert RefinedSlots.to_map(value) == input
      assert RefinedSlots.sorted_records(value) == MmoContracts.Voxel.Refined.slot_records(input)
      assert RefinedSlots.reduce_sorted(value, [], fn row, rows -> [row | rows] end)
             |> Enum.reverse() == Enum.sort(input)
      for {slot, row} <- input, do: assert(RefinedSlots.fetch(value, slot) == {:ok, row})
      assert :binary.referenced_byte_size(value.data) == byte_size(value.data)
      if count == 512, do: assert(:erts_debug.flat_size(value) * 4 < :erts_debug.flat_size(input))
      assert state.refined_regions[{-1, 1, 2}][cell] == value
      assert RefinedSlots.fetch(value, count - 1) == Map.fetch(input, count - 1)
      assert RefinedSlots.fetch(value, 512) == :error
    end
  end

  test "孔洞与两端槽保持独立存在，同材质换 owner 与空宏格删除同步索引" do
    cell = {64, -1, 128}
    input = %{0 => {11, {5, 0}}, 511 => {12, {6, 1}}}
    before = Canonical.put_refined(empty(), cell, input)
    value = before.refined[cell]
    assert is_struct(value, RefinedSlots)
    assert RefinedSlots.fetch(value, 1) == :error
    assert RefinedSlots.fetch(value, 0) == {:ok, {11, {5, 0}}}
    assert RefinedSlots.fetch(value, 511) == {:ok, {12, {6, 1}}}
    {target, _} = Canonical.target_at({512, -8, 1024}, before)
    assert target == %{micro: {512, -8, 1024}, granularity: 2, incarnation: 5, owner: {5, 0}, material: 11}
    source = Map.merge(before, %{seq: 3, instances: %{{5, 0} => %{placed_by: 42}}})
    assert %{placed_by: 42, cell: ^cell} = VoxelRegion.World.Interactions.capture(source, %{cid: 7}, 2, target)
    assert VoxelRegion.ThermalGeometry.faces(cell, before.refined)
           |> Enum.map(fn {micro, neighbors} -> {micro, length(neighbors)} end) ==
      [{{512, -8, 1024}, 6}, {{519, -1, 1031}, 6}]

    changed = Canonical.put_refined(before, cell, %{0 => {11, {7, 2}}})
    assert changed.refined_owners == %{{7, 2} => MapSet.new([cell])}
    assert Canonical.changed_refined_cells(before, changed) == [cell]
    assert RefinedSlots.to_map(before.refined[cell]) == input
    deleted = Canonical.put_refined(changed, cell, %{})
    assert deleted.refined == %{}
    assert deleted.refined_regions == %{}
    assert deleted.refined_owners == %{}
  end

  test "canonical 构造边界显式拒绝越界槽、空气与截断身份" do
    for row <- [
      {512, {11, {1, 0}}},
      {-1, {11, {1, 0}}},
      {0, {0, {1, 0}}},
      {0, {65_536, {1, 0}}},
      {0, {11, {-1, 0}}},
      {0, {11, {18_446_744_073_709_551_616, 0}}},
      {0, {11, {1, 4_294_967_296}}}
    ] do
      assert_raise ArgumentError, fn ->
        Canonical.put_refined(empty(), {0, 0, 0}, Map.new([row]))
      end
    end
  end

  test "format2 外部 ETF 不能伪造已接纳的紧凑 struct 绕过首次构造校验" do
    forged = %{__struct__: RefinedSlots, count: 1, data: <<>>}
    payload = :erlang.term_to_binary(%{format: 1, value: %{{0, 0, 0} => forged}})
    assert_raise ArgumentError, fn ->
      VoxelRegion.World.Pages.unit_value(%{level: 0, region: {0, 0, 0}, segment: 2,
        chunk: {0, 0, 0}, payload: payload})
    end
  end

  test "混合材料 HP 与同宏格代表微格保留原 map 枚举，拒绝槽排序变异" do
    owner = {7, 3}
    cell = {1, -2, 3}
    input = Map.new(0..32, fn slot -> {slot, {11 + rem(slot, 2), owner}} end)
    old_order = Enum.to_list(input)
    refute old_order == Enum.sort(input)
    materials = %{11 => %{"max_hp_per_macro" => 0.1}, 12 => %{"max_hp_per_macro" => 100_000.3}}
    state = Canonical.put_refined(empty(), cell, input)
      |> Map.put(:properties, %{digest: <<1::256>>, materials: materials})
    assert is_struct(state.refined[cell], RefinedSlots)

    expected_hp = Enum.reduce(old_order, 0.0, fn {_, {material, _}}, hp ->
      hp + VoxelRegion.Damage.max_hp(Map.fetch!(materials, material), 1)
    end)
    {last_slot, {last_material, _}} = List.last(old_order)
    assert Canonical.component_max_hp(state, owner) === expected_hp
    assert %{^owner => {^expected_hp, cells, [{^cell, representative}]}} =
      Observation.snapshot_component_geometry(state, nil, [owner])
    assert cells == MapSet.new([cell])
    assert representative.micro == VoxelRegion.Prefab.micro_coord(cell, last_slot)
    assert representative.material == last_material

    # 只测试：在离线纯值内故意将记录改为 slot 升序，证明现观察断言确实拒绝顺序变异。
    records = MmoContracts.Voxel.Refined.slot_records(input)
    index = for position <- 0..32, into: <<>>, do: <<position::16-little>>
    mutant = %{state.refined[cell] | data: records <> index}
    mutated_state = put_in(state.refined[cell], mutant)
    assert_raise ExUnit.AssertionError, fn ->
      assert Observation.snapshot_component_geometry(mutated_state, nil, [owner]) ==
        %{owner => {expected_hp, cells, [{cell, representative}]}}
    end
  end
end
