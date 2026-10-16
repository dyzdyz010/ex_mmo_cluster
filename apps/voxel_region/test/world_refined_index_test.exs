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
    assert state.refined_regions == %{{0, 0, 0} => MapSet.new([a]), {1, 0, -1} => MapSet.new([b])}

    # 部件 {5, 0} 离开 a、b 整格删除：空集合连键一起去掉。
    state = state |> Canonical.put_refined(a, %{1 => {11, {6, 0}}}) |> Canonical.put_refined(b, %{})

    assert state.refined == %{a => %{1 => {11, {6, 0}}}}
    assert state.refined_owners == %{{6, 0} => MapSet.new([a])}
    assert state.refined_regions == %{{0, 0, 0} => MapSet.new([a])}
    rebuilt = Canonical.index_refined(state)
    assert {rebuilt.refined_owners, rebuilt.refined_regions} == {state.refined_owners, state.refined_regions}
  end

  test "owner cells follow the full refined iteration order" do
    refined = for x <- 0..9, y <- 0..9, into: %{}, do: {{x, y, 0}, %{0 => {11, {rem(x + y, 3) + 1, 0}}}}
    state = Canonical.index_refined(Map.merge(empty(), %{refined: refined}))
    owners = MapSet.new([{1, 0}, {3, 0}])

    assert Canonical.micro_owner_cells(state, owners) ==
             for({cell, slots} <- refined, Enum.any?(slots, fn {_, {_, o}} -> o in owners end), do: cell)
  end

  test "a write drops the cell's cached slot records" do
    cell = {2, 3, 4}
    state = Canonical.put_refined(empty(), cell, %{0 => {11, {5, 0}}})
    state = %{state | refined_encoded: %{cell => {state.refined[cell], <<1>>}, {9, 9, 9} => {%{}, <<2>>}}}
    state = Canonical.put_refined(state, cell, %{0 => {12, {5, 0}}})
    assert state.refined_encoded == %{{9, 9, 9} => {%{}, <<2>>}}
  end
end
