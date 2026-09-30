defmodule VoxelRegion.ThermalSwitchTest do
  @moduledoc """
  只测试：R8-10 温敏电导（Voxim Docs/R8/plan.md §R8-10、Design-decisions.md §2 “热了就断，玩家自己拼出恒温器”）。

  目录 = UE 发布字节 `b1aca503…` 追加一行 Test-only 温敏导体 44（σ 10 S/m、截止 373.15 K，热物性取大理石 14）；
  它还没有 UE 发布目录与客户端外观，id 在合并阶段确认。热环境 = 生产 ε 0.9。
  场景地形只经作者编辑入口，热只经 Test-only 实验热源（有限能量），电只来自热电石发电；温度全部由热内核演化。
  期望来自目录算术（r = d/(σA)）、截止温度的定义与账目恒等式，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :thermal_switch
  alias VoxelRegion.{World, Damage}
  alias VoxelRegion.TestSupport.{Log, Source}

  @digest "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @stone 11
  @copper 24
  @alloy 40
  @te 43
  @thermistor 44
  @cutoff 373.15
  @box {{-2, -2, -2}, {2, 2, 2}}

  setup do
    root = Path.join(System.tmp_dir!(), "thermal_switch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    marble = Enum.find(data["materials"], &(&1["material_id"] == 14))
    thermistor = Map.merge(marble, %{"material_id" => @thermistor, "display_name" => "Thermistor Stone (Test-only)",
      "electrical_conductivity" => 10, "electrical_cutoff_kelvin" => @cutoff})
    data = Map.update!(data, "materials", &(&1 ++ [thermistor]))
    %{root: root, data: data, materials: Map.new(data["materials"], &{&1["material_id"], &1}), ambient: 293.15}
  end

  defp catalog_file(c, name, data) do
    path = Path.join(c.root, "#{name}.json")
    File.write!(path, Jason.encode!(data))
    path
  end

  defp start(c, name) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = catalog_file(c, "#{name}/properties", c.data)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env,
      production_materials: [@stone, @copper, @alloy, @te, @thermistor]]}, id: name)
    {w, root}
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp temperature(s, c, coord), do: Map.get(cell(s, coord) || %{}, :temperature_kelvin, c.ambient)

  test "目录：温敏截止温度只能在导体上，不能与储能、塞贝克同行；追加 44 的目录可加载", c do
    assert Damage.load(catalog_file(c, "ok", c.data)).materials[@thermistor]["electrical_cutoff_kelvin"] == @cutoff
    edit = fn changes ->
      Map.update!(c.data, "materials", fn ms ->
        Enum.map(ms, &if(&1["material_id"] == @thermistor, do: Map.merge(&1, changes), else: &1))
      end)
    end
    for {name, changes} <- [nonconductor: %{"electrical_conductivity" => 0}, zero: %{"electrical_cutoff_kelvin" => 0},
          battery: %{"battery_volts_per_m" => 24, "battery_energy_per_macro_j" => 1.0e7}, seebeck: %{"seebeck_v_per_k" => 0.05}] do
      assert_raise MatchError, fn -> Damage.load(catalog_file(c, name, edit.(changes))) end
    end
  end

  # 温控开关（z = 2 平面，地面 y = 0 石）：
  #   y = 3：热铜 H (1,3)（实验热源）— 热电石 T (2,3) — 冷铜 C (3,3)
  #   y = 2：铜 (1,2)；电阻合金灯 L (3,2)
  #   y = 1：铜 (1,1) — 温敏导体 R (2,1) — 铜 (3,1)
  # 回路 H→T→C→L→(3,1)→R→(1,1)→(1,2)→H。R 经铜 (1,1)(1,2) 与热端相连：炉子热起来后 R 越过截止温度，
  # 回路断开、灯熄灭而热电石仍有开路电动势；热源耗尽、冷却到截止温度以下后 R 重新导通，灯再亮。
  test "温控开关：R 低于截止温度时 I = ε/ΣR 点灯；达到截止即断开（0 A、灯熄、热电石仍有电动势）；冷却后自动复位再点灯", c do
    {w, root} = start(c, :thermostat)
    ground = for x <- -1..5, z <- 0..4, do: {{x, 0, z}, @stone}
    cells = [{{1, 3, 2}, @copper}, {{2, 3, 2}, @te}, {{3, 3, 2}, @copper},
      {{1, 2, 2}, @copper}, {{3, 2, 2}, @alloy},
      {{1, 1, 2}, @copper}, {{2, 1, 2}, @thermistor}, {{3, 1, 2}, @copper}]
    {:ok, _} = World.apply_edits(w, ground ++ cells)
    path = Path.join(root, "heat.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [1, 3, 2], ambient_kelvin: c.ambient,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8, power_w: 5.0e5, energy_j: 1.0e8}))
    :ok = World.thermal_experiment(w, path)

    sigma = fn m -> c.materials[m]["electrical_conductivity"] end
    # ΣR：T、L、R 各两个半格，铜半格 10 个（H、C、(3,1)、(1,1)、(1,2) 各两个）。
    r = 2 * 0.5 / sigma.(@te) + 2 * 0.5 / sigma.(@alloy) + 2 * 0.5 / sigma.(@thermistor) + 10 * 0.5 / sigma.(@copper)
    te = fn s -> cell(s, {2, 3, 2}) end
    lamp = fn s -> cell(s, {3, 2, 2}) end
    # 每次提交先按提交前的温度求解、再推进热：一次提交写下的电流对应上一次提交结束时 R 的温度。
    step = fn pred, limit, from ->
      Enum.reduce_while(1..limit, {nil, from}, fn _, {_, s0} ->
        s = commit(w)
        if pred.(s), do: {:halt, {s0, s}}, else: {:cont, {s0, s}}
      end)
    end
    current = fn s -> Map.get(te.(s) || %{}, :source_current_a, 0.0) end

    # 1. 导通：热电石发电、R 还冷，按 ε/ΣR 点灯。
    {before_lit, lit} = step.(&(current.(&1) > 1.0), 2000, observe(w))
    assert current.(lit) > 1.0
    assert temperature(before_lit, c, {2, 1, 2}) < @cutoff
    t = te.(lit)
    assert_in_delta t.source_current_a, t.source_emf_v / r, t.source_current_a * 1.0e-8
    assert_in_delta lamp.(lit).electric_w, t.source_current_a ** 2 * 2 * 0.5 / sigma.(@alloy), lamp.(lit).electric_w * 1.0e-6
    IO.puts("THERMOSTAT_LIT current=#{t.source_current_a} emf=#{t.source_emf_v} r_k=#{temperature(before_lit, c, {2, 1, 2})} elapsed=#{lit.thermal.elapsed_s}")

    # 2. 断开：R 达到截止温度的下一次求解严格 0 A、灯的电功率观察撤下；热电石开路电动势仍在（断开的是 R，不是电源）。
    {before_cut, cut} = step.(&(current.(&1) == 0.0), 4000, lit)
    assert current.(cut) == 0.0
    assert temperature(before_cut, c, {2, 1, 2}) >= @cutoff
    assert te.(cut).source_emf_v > 1.0
    refute Map.has_key?(lamp.(cut), :electric_w)
    light = cut.thermal.circuit_light_j
    held = step.(fn _ -> false end, 4, cut) |> elem(1)
    assert held.thermal.circuit_light_j == light
    IO.puts("THERMOSTAT_CUT emf=#{te.(cut).source_emf_v} r_k=#{temperature(before_cut, c, {2, 1, 2})} hot_k=#{temperature(before_cut, c, {1, 3, 2})} elapsed=#{cut.thermal.elapsed_s}")

    # 3. 复位：热源耗尽后冷却，R 回到截止温度以下的下一次求解重新导通，按 ε/ΣR 点灯。
    {before_on, on} = step.(&(current.(&1) > 0.0), 20_000, held)
    assert temperature(before_on, c, {2, 1, 2}) < @cutoff
    t = te.(on)
    assert t.source_current_a > 0.0
    assert_in_delta t.source_current_a, t.source_emf_v / r, t.source_current_a * 1.0e-8
    assert lamp.(on).electric_w > 0.0
    assert on.thermal.circuit_light_j > light
    IO.puts("THERMOSTAT_RESET current=#{t.source_current_a} emf=#{t.source_emf_v} r_k=#{temperature(before_on, c, {2, 1, 2})} hot_k=#{temperature(before_on, c, {1, 3, 2})} elapsed=#{on.thermal.elapsed_s}")
  end
end
