defmodule VoxelRegion.CircuitAdmissionTest do
  @moduledoc "只测试：潜在空间图与人工计数的小确定输入；不启动World、数据库或第二求解器。"
  use ExUnit.Case, async: true
  alias VoxelRegion.{Circuit, Damage, Protection, RefinedSlots}
  alias VoxelRegion.World.{Canonical, CircuitAdmission, CircuitGraph}

  defp target(x, material), do: %{micro: {x * 8, 0, 0}, granularity: 0,
    material: material, owner: {0, 0}, incarnation: 1}

  defp state(materials, placed) do
    empty = for x <- -2..6, y <- -2..2, z <- -2..2, into: %{}, do: {{0, {x, y, z}}, {0, 0}}
    overlay = Enum.reduce(materials, empty, fn {x, material}, acc -> Map.put(acc, {0, {x, 0, 0}}, {material, 0}) end)
    %{seq: 1, resident: :all, overlay: overlay, refined: %{}, epochs: %{}, macro_owners: %{},
      placed_by: Canonical.chunk_merge(%{}, Map.new(placed, &{{&1, 0, 0}, 1001})), instances: %{},
      liquid_units: %{}, attachments: %{}, protection: Protection.new(), damage: %{}, thermal: nil,
      properties: %{materials: %{0 => %{}, 24 => %{"electrical_conductivity" => 10.0},
        41 => %{"electrical_conductivity" => 10.0, "circuit_switch" => true},
        42 => %{"electrical_conductivity" => 10.0, "battery_volts_per_m" => 24.0},
        45 => %{"electrical_conductivity" => 10.0, "electrical_cutoff_kelvin" => 300.0}}}}
    |> Canonical.index_attachments()
  end

  test "潜在图忽略开关与温度，天然桥不计人工量，宏格微格各1、附件按件计1" do
    s = state([{0, 24}, {1, 41}, {2, 45}], [0])
    hot = Map.put(target(2, 45), :temperature_kelvin, 400.0)
    s = %{s | damage: %{Damage.key(hot) => hot}}
    assert {:ready, graph, _} = CircuitGraph.advance(s, CircuitGraph.potential(1, {:solid, target(0, 24)}, s.protection))
    assert MapSet.size(graph.solids) == 3
    assert CircuitAdmission.artificial_units(s, graph) == 1
    refute Circuit.sigma(s.properties, s.damage, %{"ambient_kelvin" => 293.15}, target(1, 41)) > 0
    refute Circuit.sigma(s.properties, s.damage, %{"ambient_kelvin" => 293.15}, target(2, 45)) > 0

    cell = {3, 0, 0}
    slots = RefinedSlots.from_map(%{0 => {24, {4, 0}}})
    attachment = {1, 0, {24, 0, 0}}
    s = %{s | refined: %{cell => slots}, instances: %{{4, 0} => %{placed_by: 1001}},
      attachments: %{attachment => {9, 24}}} |> Canonical.index_attachments()
    assert {:ready, graph, _} = CircuitGraph.advance(s, CircuitGraph.potential(1, {:solid, target(0, 24)}, s.protection))
    assert CircuitAdmission.artificial_units(s, graph) == 3
  end

  # 用户 2026-10-29 决定：一块附件（同一出生 ID 的全部槽）只计 1；宏格、微格仍各计 1，上限 27 不变。
  test "整块64槽导电面与人工宏格相连按1件计，旧逐槽口径会误拒" do
    s = state([{0, 24}, {1, 24}, {2, 24}], [0, 1, 2])
    face = for u <- 0..7, v <- 0..7, into: %{}, do: {{0, 0, {24, u, v}}, {7, 24}}
    current = Canonical.index_attachments(%{s | attachments: face})
    assert {:ready, graph, _} = CircuitGraph.advance(current, CircuitGraph.potential(1, {:solid, target(0, 24)}, s.protection))
    assert map_size(graph.slots) == 64
    assert CircuitAdmission.artificial_units(current, graph) == 4
    assert {:ok, _} = CircuitAdmission.check(s, current, [], Map.keys(face), 27)
  end

  test "28块各自独立出生的附件经共享端点连成一片时超过27拒绝" do
    s = state([], [])
    slots = for u <- 0..6, v <- 0..3, into: %{}, do: {{0, 0, {24, u, v}}, {100 + u * 4 + v, 24}}
    current = Canonical.index_attachments(%{s | attachments: slots})
    assert {:error, :circuit_component_limit} = CircuitAdmission.check(s, current, [], Map.keys(slots), 27)
  end

  test "同潜在拓扑只换身份不会拒绝旧大分量，蓄能石变普通导体的新侧接触会检查" do
    before = state([{0, 24}, {1, 24}], [0, 1])
    after_state = %{before | epochs: VoxelRegion.EpochChunk.merge(%{}, %{{0, 0, 0} => 8})}
    assert {:ok, _} = CircuitAdmission.check(before, after_state, [{0, 0, 0}], [], 1)
    battery = %{before | overlay: Map.put(before.overlay, {0, {0, 0, 0}}, {42, 0})}
    assert {:error, :circuit_component_limit} = CircuitAdmission.check(battery, before, [{0, 0, 0}], [], 1)
    assert {:ok, _} = CircuitAdmission.check(before, battery, [{0, 0, 0}], [], 1)
  end

  test "多个新增但不相连的分量分别计数，不把整笔总量当分量上限" do
    before = state([], [])
    current = state([{0, 24}, {4, 24}], [0, 4])
    assert {:ok, _} = CircuitAdmission.check(before, current, [{0, 0, 0}, {4, 0, 0}], [], 1)
  end

  test "冷页返回同一输入的已读与新缺页依赖，不能部分图成功" do
    before = state([], [])
    current = state([{0, 24}], [0])
    current = %{current | resident: MapSet.new([{0, {0, 0, 0}}])}
    assert {:error, {:pages_missing, keys}} = CircuitAdmission.check(before, current, [{0, 0, 0}], [], 1)
    assert {0, {0, 0, 0}} in keys
    assert {0, {-1, 0, 0}} in keys
    assert Enum.all?(keys, fn {_level, region} -> tuple_size(region) == 3 end)
  end

  test "后一个分量缺页时仍保留同笔输入此前分量的读取依赖" do
    before = state([], [])
    before = %{before | overlay: Map.put(before.overlay, {0, {128, 0, 0}}, {0, 0})}
    current = state([{0, 24}, {128, 24}], [0, 128])
    resident = for x <- -1..0, y <- -1..0, z <- -1..0, into: MapSet.new(), do: {0, {x, y, z}}
    current = %{current | resident: MapSet.put(resident, {0, {2, 0, 0}})}
    assert {:error, {:pages_missing, keys}} =
      CircuitAdmission.check(before, current, [{0, 0, 0}, {128, 0, 0}], [], 1)
    assert {0, {0, 0, 0}} in keys
    assert {0, {1, 0, 0}} in keys
  end
end
