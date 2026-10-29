defmodule VoxelRegion.WindowPropertyTest do
  @moduledoc "只测试：属性投影纯函数的窗口、跨区整件 HP、目录与占用失效；期望来自手算微格体积。"
  use ExUnit.Case, async: false
  alias VoxelRegion.World.{Canonical, Observation}

  defp fixture do
    state = %{refined: %{}, refined_owners: %{}, refined_regions: %{},
      component_cache: %{}, properties: %{digest: <<1::256>>, materials: %{11 => %{"max_hp_per_macro" => 512, "defense" => 2}}},
      seq: 9, damage: %{}, thermal: nil}
    state
    |> Canonical.put_refined({-1, 2, 3}, %{0 => {11, {3, 0}}, 1 => {11, {3, 0}}})
    |> Canonical.put_refined({64, 2, 3}, %{0 => {11, {3, 0}}, 1 => {11, {4, 0}}})
    |> Canonical.put_refined({0, 200, 0}, Map.new(0..511, &{&1, {11, {5, 0}}}))
  end

  test "窗口外叶子不求 HP；跨区叶子仍计全件，重复窗口不重复逐微格汇总" do
    state = fixture()
    box = {{-1, 0, 0}, {0, 1, 1}}
    # 当前真实窗口投影路径；调用计数直接证伪再次全量逐微格汇总，不使用墙钟阈值。
    Code.ensure_loaded!(VoxelRegion.Damage)
    :erlang.trace_pattern({VoxelRegion.Damage, :max_hp, 2}, true, [:call_count])
    on_exit(fn -> :erlang.trace_pattern({VoxelRegion.Damage, :max_hp, 2}, false, [:call_count]) end)
    [row] = Observation.component_observations(state, box)
    assert row.owner == {3, 0} and row.hp == 3.0 and row.max_hp == 3.0
    assert MapSet.new(row.observation_cells) == MapSet.new([{-1, 2, 3}, {64, 2, 3}])
    {:call_count, count} = :erlang.trace_info({VoxelRegion.Damage, :max_hp, 2}, :call_count)
    assert count == 3
    state = Observation.prepare_component_cache(state, box)
    :erlang.trace_pattern({VoxelRegion.Damage, :max_hp, 2}, true, [:call_count])
    assert Observation.component_observations(state, box) == [row]
    assert :erlang.trace_info({VoxelRegion.Damage, :max_hp, 2}, :call_count) == {:call_count, 0}
    damaged = %{state | damage: %{VoxelRegion.Damage.key(row) => %{row | hp: 1.25}}}
    assert [current] = Observation.component_observations(damaged, box)
    assert current.hp == 1.25 and current.max_hp == 3.0
    # 同一 owner 在窗外的几何变了：整件 HP 必须失效，不能只看窗口内是否改动。
    edited = Canonical.put_refined(state, {64, 2, 3}, %{0 => {11, {3, 0}}, 2 => {11, {3, 0}}})
    [next] = Observation.component_observations(edited, box)
    assert next.hp == 4.0
    catalog = %{edited.properties | digest: <<2::256>>, materials: %{11 => %{"max_hp_per_macro" => 1024, "defense" => 2}}}
    [next] = Observation.component_observations(%{edited | properties: catalog}, box)
    assert next.hp == 8.0
  end
end
