defmodule VoxelRegion.DeviceMaterialProductionTest do
  @moduledoc """
  只测试：R8-04 增量 1（器件材料化第一步）在 UE 发布的目录字节上核对，增量 2 起用 `0c67824f…`（DA_MaterialCoverageV1：
  开关材料 41、撤下开关／灯／加热器／冷板设备工具）与生产热环境（ε 0.9，数值与 `environment-radiation.json` 相同）。
  电阻合金 40：σ 4 S/m、λ 0.2、C 40 kJ/(m³K)、k 25、耐热 1900 K；铁矿石 17 在 1373.15 K 接触煤时单向转化成 40。

  场景经作者编辑入口一次建立；时间只经 :thermal_commit 推进。期望来自目录算术，不取自内核输出。
  增量 3 撤下电源设备后，这里原有的“24 V 源 + 合金灯”“480 V 源 + 合金板点燃木头”两项随电源退役删除：合金灯由
  energy_material_test 以蓄能石（热电石充电）供电核对，接触边按电阻份额分热与发光份额由 circuit_test 核对。
  """
  use ExUnit.Case, async: false
  @moduletag :device_material
  alias VoxelRegion.World

  defmodule NullLog do
    @moduledoc "只测试：不落盘的日志替身。"
    def open(dir, _), do: dir
    def replay(_), do: []
    def append(_, _), do: :ok
    def checkpoint(_, _), do: :ok
  end

  @digest "0c67824f97992de46ea7306b3e7596b6b29eea3d51e4e2a226bf947b2cf21552"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @stone 11
  @coal 15
  @iron_ore 17
  @copper 24
  @alloy 40
  @switch 41
  @micro 1 / 8
  @micro_area 1 / 64

  setup do
    root = Path.join(System.tmp_dir!(), "device_material_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(@fixtures, @digest <> ".json")
    data = Jason.decode!(File.read!(path))
    %{root: root, path: path, data: data, ambient: 293.15,
      materials: Map.new(data["materials"], &{&1["material_id"], &1}), tools: Map.new(data["tools"], &{&1["tool_id"], &1}),
      units: data["attachments"]["material_units_per_micro"]}
  end

  defp start(c, name) do
    root = Path.join(c.root, "#{name}")
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    catalog = Path.join(root, "properties.json")
    File.cp!(c.path, catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    w = start_supervised!({World, [source: VoxelRegion.TestSupport.Source, log: NullLog, root: root, observer: self(),
      name: nil, property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: prefabs,
      production_materials: [@stone, @coal, @iron_ore, @copper, @alloy, @switch]]}, id: name)
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@coal => 10_000_000, @copper => 10_000_000})
    {w, prefabs}
  end

  defp observe(w, box), do: VoxelRegion.TestSupport.observe(w, [], box)
  defp row(s, micro), do: Enum.find(Map.values(s.damage), &(&1.micro == micro and &1.granularity in [0, 1]))

  test "夹具即 UE 发布字节；目录里电阻合金与铁矿冶炼规则按作者值发布", c do
    assert Base.encode16(:crypto.hash(:sha256, File.read!(c.path)), case: :lower) == @digest
    alloy = c.materials[@alloy]
    assert {alloy["electrical_conductivity"], alloy["luminous_fraction"], alloy["heat_capacity_per_macro"],
            alloy["heat_resistance_kelvin"]} == {4, 0.2, 40000, 1900}
    ore = c.materials[@iron_ore]
    assert {ore["transform_material_id"], ore["transform_kelvin"], ore["transform_reductant_material_id"]} == {@alloy, 1373.15, @coal}
    # 几何决定角色：一个微格 2 Ω（灯丝），整格 0.25 Ω，8×6 微格板夹在铜排间 1.5 Ω（旧加热器）。
    assert_in_delta @micro / (4 * @micro_area), 2.0, 1.0e-12
    assert_in_delta 1 / (4 * 1.0), 0.25, 1.0e-12
    assert_in_delta 6 * 2.0 / 8, 1.5, 1.0e-12
  end

  test "铁矿石接触煤、加热越过 1373.15 K：整格单向变成电阻合金，还原剂按 0.25 × 煤燃料扣减", c do
    {w, _} = start(c, :smelt)
    {:ok, _} = World.apply_edits(w, [{{2, 0, 2}, @stone}, {{2, 1, 2}, @iron_ore}, {{3, 1, 2}, @coal}])
    # Test-only 热源（与 transform_world_test 同一实验入口）；辐射关闭以免 500 kW 源的场景依赖视线。
    path = Path.join(c.root, "heat.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [2, 1, 2], ambient_kelvin: c.ambient,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, power_w: 500_000.0, energy_j: 6.0e7}))
    :ok = World.thermal_experiment(w, path)
    box = {{0, 0, 0}, {6, 4, 6}}
    s = Enum.reduce_while(1..4000, nil, fn _, _ ->
      send(w, :thermal_commit)
      s = observe(w, box)
      if match?(%{material: @alloy}, row(s, {16, 8, 16})), do: {:halt, s}, else: {:cont, s}
    end)
    product = row(s, {16, 8, 16})
    assert product.material == @alloy
    assert s.thermal.transform_units == 512 * c.units
    assert_in_delta s.thermal.transform_reductant_fuel_j, 0.25 * c.materials[@coal]["fuel_energy_per_macro_j"], 1.0e-3
    # 产物温度不低于在 X 转化所能留下的下限：Ta + (C_ore (X − Ta) − 反应热) / C_alloy。
    ore = c.materials[@iron_ore]
    floor = c.ambient + (ore["heat_capacity_per_macro"] * (ore["transform_kelvin"] - c.ambient) - ore["transform_heat_per_macro_j"]) /
      c.materials[@alloy]["heat_capacity_per_macro"]
    assert product.temperature_kelvin >= floor
    IO.puts("DEVICE_SMELT alloy_temperature=#{product.temperature_kelvin} floor=#{floor} elapsed=#{s.thermal.elapsed_s}")
  end
end
