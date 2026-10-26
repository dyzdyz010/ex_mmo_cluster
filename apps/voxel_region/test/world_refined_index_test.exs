defmodule VoxelRegion.WorldRefinedIndexTest do
  use ExUnit.Case, async: true

  alias VoxelRegion.World.Canonical

  # 只测试：refined 派生索引的增量维护。期望是手算的部件／区域 => 宏格集合，并与按整表重建的结果相同。
  defp empty, do: %{refined: %{}, refined_owners: %{}, refined_regions: %{}, refined_encoded: %{}}

  test "put_refined keeps owner and region indexes equal to a full rebuild" do
    a = {1, 1, 1}
    b = {70, 1, -1}

    state =
      empty()
      |> Canonical.put_refined(a, %{0 => {11, {5, 0}}, 1 => {11, {6, 0}}})
      |> Canonical.put_refined(b, %{0 => {12, {5, 0}}})

    assert state.refined_owners == %{{5, 0} => MapSet.new([a, b]), {6, 0} => MapSet.new([a])}
    # 区域索引存该区的 refined 子表（与 refined 同一槽值）。
    assert state.refined_regions == %{{0, 0, 0} => %{a => state.refined[a]}, {1, 0, -1} => %{b => state.refined[b]}}

    # 部件 {5, 0} 离开 a、b 整格删除：空集合连键一起去掉。
    state = state |> Canonical.put_refined(a, %{1 => {11, {6, 0}}}) |> Canonical.put_refined(b, %{})

    assert state.refined == %{a => %{1 => {11, {6, 0}}}}
    assert state.refined_owners == %{{6, 0} => MapSet.new([a])}
    assert state.refined_regions == %{{0, 0, 0} => %{a => %{1 => {11, {6, 0}}}}}
    rebuilt = Canonical.index_refined(state)
    assert {rebuilt.refined_owners, rebuilt.refined_regions} == {state.refined_owners, state.refined_regions}
  end

  # 父稿 Q5（用户已批准）：部件格按格坐标的确定序，不随驻留的 refined 整表遍历次序变化（M2b 按需装页后整表随装页历史不同）。
  test "owner cells follow the deterministic cell order" do
    refined = for x <- 0..9, y <- 0..9, into: %{}, do: {{x, y, 0}, %{0 => {11, {rem(x + y, 3) + 1, 0}}}}
    state = Canonical.index_refined(Map.merge(empty(), %{refined: refined}))
    owners = MapSet.new([{1, 0}, {3, 0}])
    expected = for x <- 0..9, y <- 0..9, rem(x + y, 3) + 1 in [1, 3], do: {x, y, 0}

    assert Canonical.micro_owner_cells(state, owners) == Enum.sort(expected)
    # 只留一部分格（另一次装页历史）时，剩下的格相对次序不变。
    partial = Canonical.index_refined(Map.merge(empty(), %{refined: Map.take(refined, Enum.take_every(Map.keys(refined), 3))}))
    assert Canonical.micro_owner_cells(partial, owners) == Enum.filter(Enum.sort(expected), &Map.has_key?(partial.refined, &1))
  end

  test "changed refined cells are exactly the cells whose slots differ" do
    a = {1, 1, 1}
    b = {70, 1, -1}
    c = {-1, -1, -1}

    before =
      empty()
      |> Canonical.put_refined(a, %{0 => {11, {5, 0}}})
      |> Canonical.put_refined(b, %{0 => {12, {5, 0}}})

    # 同区改值（a）、跨区新增（c）、删除（b）；同一区域里未改的格不算。
    state =
      before
      |> Canonical.put_refined(a, %{0 => {13, {5, 0}}})
      |> Canonical.put_refined(c, %{3 => {11, {7, 0}}})
      |> Canonical.put_refined(b, %{})
      |> Canonical.put_refined({2, 2, 2}, %{0 => {11, {5, 0}}})

    after_extra = Canonical.put_refined(state, {2, 2, 2}, %{0 => {11, {5, 0}}})
    assert Enum.sort(Canonical.changed_refined_cells(before, state)) == Enum.sort([a, b, c, {2, 2, 2}])
    assert Canonical.changed_refined_cells(state, after_extra) == []
    assert Canonical.changed_refined_cells(state, state) == []
  end

  test "put_macro_owner keeps region and owner indexes equal to a full rebuild" do
    # 只测试：macro_owners 派生索引。手算：(1,1,1) 与 (63,0,0) 在区域 {0,0,0}，(-1,0,64) 在 {-1,0,1}。
    a = {1, 1, 1}
    b = {63, 0, 0}
    c = {-1, 0, 64}
    empty = %{macro_owners: %{}, macro_owner_regions: %{}, macro_owner_cells: %{}}

    state =
      empty
      |> Canonical.put_macro_owner(a, {5, 0})
      |> Canonical.put_macro_owner(b, {5, 0})
      |> Canonical.put_macro_owner(c, {6, 1})

    assert state.macro_owner_regions == %{{0, 0, 0} => %{a => {5, 0}, b => {5, 0}}, {-1, 0, 1} => %{c => {6, 1}}}
    assert state.macro_owner_cells == %{{5, 0} => MapSet.new([a, b]), {6, 1} => MapSet.new([c])}

    # 换归属、删除（nil）、删不存在的格。
    state =
      state
      |> Canonical.put_macro_owner(a, {6, 1})
      |> Canonical.put_macro_owner(b, nil)
      |> Canonical.put_macro_owner({9, 9, 9}, nil)

    assert state.macro_owners == %{a => {6, 1}, c => {6, 1}}
    assert state.macro_owner_regions == %{{0, 0, 0} => %{a => {6, 1}}, {-1, 0, 1} => %{c => {6, 1}}}
    assert state.macro_owner_cells == %{{6, 1} => MapSet.new([a, c])}
    rebuilt = Canonical.index_macro_owners(state)
    assert {rebuilt.macro_owner_regions, rebuilt.macro_owner_cells} == {state.macro_owner_regions, state.macro_owner_cells}
    assert Enum.sort(Canonical.macro_owners_in_regions(state, [{0, 0, 0}, {0, 0, 0}])) == [{a, {6, 1}}]
  end

  test "put_liquid keeps the region index equal to a full rebuild; zero deletes" do
    # 只测试：liquid_units 派生索引。手算：(0,0,0) 与 (63,5,1) 在区域 {0,0,0}，(-1,0,0) 在 {-1,0,0}。
    empty = %{liquid_units: %{}, liquid_regions: %{}}
    state = Canonical.put_liquid(empty, %{{0, 0, 0} => 4096, {63, 5, 1} => 10, {-1, 0, 0} => 7})
    assert state.liquid_regions == %{{0, 0, 0} => %{{0, 0, 0} => 4096, {63, 5, 1} => 10}, {-1, 0, 0} => %{{-1, 0, 0} => 7}}

    state = Canonical.put_liquid(state, [{{0, 0, 0}, 0}, {{-1, 0, 0}, 0}, {{63, 5, 1}, 11}, {{9, 9, 9}, 0}])
    assert state.liquid_units == %{{63, 5, 1} => 11}
    assert state.liquid_regions == %{{0, 0, 0} => %{{63, 5, 1} => 11}}
    assert Canonical.index_liquid(state).liquid_regions == state.liquid_regions
    assert Canonical.liquid_in_regions(state, [{0, 0, 0}, {-1, 0, 0}]) == [{{63, 5, 1}, 11}]
  end

  test "a write drops the cell's cached slot records" do
    cell = {2, 3, 4}
    state = Canonical.put_refined(empty(), cell, %{0 => {11, {5, 0}}})
    state = %{state | refined_encoded: %{cell => {state.refined[cell], <<1>>}, {9, 9, 9} => {%{}, <<2>>}}}
    state = Canonical.put_refined(state, cell, %{0 => {12, {5, 0}}})
    assert state.refined_encoded == %{{9, 9, 9} => {%{}, <<2>>}}
  end
  test "chunk-nested cell tables: floor chunks, empty chunks dropped, flat view and box filter" do
    # 手算：16³ 子块向负无穷取整，{-1, 0, 17} 在子块 {-1, 0, 1}，{15, 0, 0} 在 {0, 0, 0}。
    a = {-1, 0, 17}
    b = {15, 0, 0}
    t = Canonical.chunk_merge(%{}, %{a => 7, b => 9})
    assert t == %{{-1, 0, 1} => %{a => 7}, {0, 0, 0} => %{b => 9}}
    assert Canonical.chunk_get(t, a) == 7 and Canonical.chunk_get(t, {0, 0, 0}, 0) == 0
    assert Canonical.chunk_flat(t) == %{a => 7, b => 9}
    # 盒是 L0 区域坐标、上界不含（与 PropertyObservation.contains?/2 同一判定）。
    assert Canonical.chunk_flat(t, {{0, 0, 0}, {1, 1, 1}}) == %{b => 9}
    assert Canonical.chunk_delete(t, a) == %{{0, 0, 0} => %{b => 9}}
    assert Canonical.chunk_put(t, b, 10) |> Canonical.chunk_get(b) == 10
  end
end
