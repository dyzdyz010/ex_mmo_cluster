defmodule VoxelRegion.TransformFurnaceTest do
  @moduledoc """
  只测试：R8 §10 ①② 闭环——辐射换热（ε 0.9）下，同一堆"煤环 + 矿 + 煤盖"在 5³ 石炉内达到转化温度并炼成铜，
  露天则不能。目录夹具 = 已发布 fbd4f301 字节 + 设计研究的参数组 R（煤 k 25 W/(m K)、热阻 2273.15 K；
  Stone/CopperOre/Copper 热阻 1600 K）+ CopperOre 转化字段（X 1358.15 K、反应热 1 MJ/m³、每单位矿耗 0.25 单位煤）。

  夹具：煤堆与地面由作者编辑入口建立；九块煤各经正式点火工具 9 按两次点燃（2×3.125 MJ 越过 673.15 K），
  随后作者入口补齐炉壁（门在 +x 面 (4,1,2)）。真实内核里接触导热（25 W/K）不足以把火从一块煤传到邻煤，
  所以"全部点燃"是夹具前提而不是被验证的行为。持久化不在本测试范围，日志用不落盘的替身。
  """
  use ExUnit.Case, async: false
  @moduletag :transform_furnace
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.Actor

  defmodule NullLog do
    @moduledoc "只测试：不落盘的日志替身；本测试不重启 World。"
    def open(dir, _), do: dir
    def replay(_), do: []
    def append(_, _), do: :ok
    def checkpoint(_, _), do: :ok
  end

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @digest "fbd4f30106f1cecbd5ea73cb361b7e19058a531420fbaf86998ad89f43f6ba70"
  @ambient 293.15
  @x 1358.15
  @ratio 0.25
  @ore {2, 1, 2}

  defp pile, do: (for x <- 1..3, z <- 1..3, {x, z} != {2, 2}, do: {{x, 1, z}, 15}) ++ [{@ore, 16}, {{2, 2, 2}, 15}]
  defp ground, do: for(x <- 0..4, z <- 0..4, do: {{x, 0, z}, 11})
  defp walls, do: for(x <- 0..4, y <- 1..4, z <- 0..4, not (x in 1..3 and y in 1..3 and z in 1..3), {x, y, z} != {4, 1, 2}, do: {{x, y, z}, 11})

  setup do
    root = Path.join(System.tmp_dir!(), "furnace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    data = Map.update!(data, "materials", &Enum.map(&1, fn m ->
      case m["material_id"] do
        15 -> Map.merge(m, %{"thermal_conductivity" => 25, "heat_resistance_kelvin" => 2273.15})
        id when id in [11, 24] -> Map.put(m, "heat_resistance_kelvin", 1600)
        16 -> Map.merge(m, %{"heat_resistance_kelvin" => 1600, "transform_material_id" => 24, "transform_kelvin" => @x,
          "transform_heat_per_macro_j" => 1.0e6, "transform_reductant_material_id" => 15,
          "transform_reductant_units_per_unit" => @ratio})
        _ -> m
      end
    end))
    %{root: root, data: data, materials: Map.new(data["materials"], &{&1["material_id"], &1})}
  end

  defp start(c, name) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(c.data))
    env = Path.join(root, "environment.json")
    File.write!(env, Jason.encode!(%{ambient_kelvin: @ambient, environment_w_per_m2_k: 10, tolerance_kelvin: 1,
      emissivity: 0.9, view_range_cells: 8}))
    start_supervised!({World, [source: VoxelRegion.TestSupport.Source, log: NullLog, root: root, observer: self(),
      name: nil, property_catalog_path: catalog, thermal_environment_path: env, production_materials: [11, 15, 16]]}, id: name)
  end

  defp ignite_all(w) do
    {:ok, _} = World.material_supply(w, 1001, "ignite", %{15 => 200_000})
    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {2.5, 4.5, 2.5}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}, id: make_ref()))
    coal = for {cell, 15} <- pile(), do: cell
    for {{x, _, z}, i} <- Enum.with_index(coal), press <- 0..1 do
      seq = i * 2 + press + 1
      eye = {x + 0.5, 4.5, z + 0.5}
      :ok = GenServer.call(actor.player, {:eye, eye})
      q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 9, direction: {0.0, -1.0, 0.0},
        micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
      {:ok, t} = World.tool_intent(w, actor, q)
      r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material])) |> Map.put(:action, 1)
      {:ok, _} = World.tool_intent(w, %{actor | eye: eye} |> Map.merge(%{received_us: seq * 1_000_000, clock_node: node()}), r)
    end
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [], {{-1, -1, -1}, {6, 6, 6}})
  defp material(w), do: hd(World.material_snapshot(w, [], [@ore]).probe_occupancy).material

  # 只看同一快照，避免与后台 500 ms 提交交错。
  defp copper?(s), do: Enum.any?(s.damage, fn {_, r} -> r.micro == {16, 8, 16} and r.material == 24 end)

  defp ore_temperature(s) do
    Enum.find_value(s.damage, @ambient, fn {_, r} -> r.micro == {16, 8, 16} and r.material == 16 and Map.get(r, :temperature_kelvin) end)
  end

  # 每次 0.5 s 提交后记录矿温峰值；stop? 成立或达到上限即返回。
  defp run(w, stop?, {peak, left}) do
    send(w, :thermal_commit)
    s = observe(w)
    peak = max(peak, ore_temperature(s))
    if stop?.(s) or left == 0, do: {s, peak}, else: run(w, stop?, {peak, left - 1})
  end

  defp assert_ledgers(c, s) do
    sensible = for {_, r} <- s.damage, r.granularity == 0, Map.has_key?(r, :temperature_kelvin), reduce: 0.0,
      do: (sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] * (r.temperature_kelvin - @ambient))
    ledger = s.thermal.supplied_j + s.thermal.environment_j - Map.get(s.thermal, :removed_j, 0.0) -
      Map.get(s.thermal, :transform_j, 0.0)
    assert_in_delta sensible, ledger, 1.0e-6 * s.thermal.supplied_j
    left = for {_, r} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(r, :remaining_fuel_j, 0.0))
    assert_in_delta s.thermal.fuel_initialized_j, s.thermal.combustion_j + Map.get(s.thermal, :discarded_fuel_j, 0.0) +
      Map.get(s.thermal, :transform_reductant_fuel_j, 0.0) + left, 1.0e-6 * s.thermal.fuel_initialized_j
  end

  test "辐射下石炉内的矿石越过 X 炼成铜，同一堆露天烧完也达不到 X", c do
    open = start(c, :open)
    {:ok, _} = World.apply_edits(open, ground() ++ pile())
    ignite_all(open)
    # 露天：一直烧到九块煤燃尽、全部冷却静止（名义燃期 800 MJ / 600 kW = 1333 s）。
    {settled, open_peak} = run(open, &(not &1.thermal.active), {0.0, 20_000})
    refute settled.thermal.active
    assert material(open) == 16
    refute Map.has_key?(settled.thermal, :transform_units)
    assert open_peak < @x
    assert_ledgers(c, settled)

    furnace = start(c, :furnace)
    {:ok, _} = World.apply_edits(furnace, ground() ++ pile())
    ignite_all(furnace)
    {:ok, _} = World.apply_edits(furnace, walls())
    {converted, furnace_peak} = run(furnace, &copper?/1, {0.0, 20_000})
    assert material(furnace) == 24
    # 触发温度 ≥ X 由 transform_world_test 在转化前一笔提交上核对；此处观察到的是转化前一拍的矿温。
    assert converted.thermal.transform_units == c.data["attachments"]["material_units_per_micro"] * 512
    assert_in_delta converted.thermal.transform_reductant_fuel_j, @ratio * c.materials[15]["fuel_energy_per_macro_j"], 1.0e-3
    assert_ledgers(c, converted)
    IO.puts("TRANSFORM_FURNACE open_peak=#{open_peak} furnace_converted_at=#{converted.thermal.elapsed_s} ore_before=#{furnace_peak}")
  end
end
