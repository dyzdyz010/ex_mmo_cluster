defmodule VoxelRegion.FireFurnaceProductionTest do
  @moduledoc """
  只测试：R8 §10 火与炉的一次目录调参（2026-09-24），在 UE 发布的目录字节与 Test-only 辐射热环境（ε 0.9）上核对。

  目录夹具 `fixtures/combustion/<digest>.json` = `DA_MaterialCoverageV1` 的发布字节（文件名即 sha256）；热环境夹具
  `environment-radiation.json` = `Content/Voxel/Gameplay/thermal-environment-radiation.json`（DA_ThermalEnvironmentRadiation_TestOnly）。
  这套目录只在辐射开启时成立：ε 0 下 400 kW 的木格会过热自毁，所以青岚驿（ε 0）停在旧目录，见 Voxim Docs/Playtest/README.md。

  场景由作者编辑入口一次建立，点火经正式工具 9（K）；时间只经 :thermal_commit 推进。原“电点火闭环现场”（480 V 源 + 开关设备 + 加热器设备）
  随 R8-04 增量 2 撤下加热器与开关设备而删除，电阻合金板点燃木头由 device_material_production_test 覆盖。
  期望来自目录算术（燃期 fuel/P、点火温度、反应物账）或设计阈值（露天堆比转化温度低 ≥ 100 K、60 s 内引燃邻木、
  炉体与产物不被热毁、火烧完后活动集清空），不取自内核输出。持久化不在本测试范围，日志用不落盘的替身。
  """
  use ExUnit.Case, async: false
  @moduletag :fire_production
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.Actor

  defmodule NullLog do
    @moduledoc "只测试：不落盘的日志替身；本测试不重启 World。"
    def open(dir, _), do: dir
    def replay(_), do: []
    def append(_, _), do: :ok
    def checkpoint(_, _), do: :ok
  end

  @digest "5be2e8c79d8789a29aa17e023294c8aafbff51ff4b8c07a945035dbfcf91fe57"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @grass 1
  @dirt 7
  @stone 11
  @coal 15
  @ore 16
  @wood 19
  @copper 24
  @spruce 27
  @box {{-2, -2, -2}, {12, 14, 12}}

  setup do
    root = Path.join(System.tmp_dir!(), "fire_production_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(@fixtures, @digest <> ".json")
    data = Jason.decode!(File.read!(path))
    env = Jason.decode!(File.read!(Path.join(@fixtures, "environment-radiation.json")))
    %{root: root, path: path, data: data, env: env, ambient: env["ambient_kelvin"],
      materials: Map.new(data["materials"], &{&1["material_id"], &1}), tools: Map.new(data["tools"], &{&1["tool_id"], &1}),
      units: data["attachments"]["material_units_per_micro"]}
  end

  defp start(c, name, production) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    File.cp!(c.path, catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    w = start_supervised!({World, [source: VoxelRegion.TestSupport.Source, log: NullLog, root: root, observer: self(),
      name: nil, property_catalog_path: catalog, thermal_environment_path: env,
      production_materials: Enum.uniq([@coal | production])]}, id: name)
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@coal => 10_000_000})
    w
  end

  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  # 工具 9（K）一次：先取目标，再以同一目标执行。
  defp ignite(w, eye, direction, seq) do
    a = actor(eye)
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 9, direction: direction,
      micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, t} = World.tool_intent(w, a, q)
    r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material])) |> Map.put(:action, 1)
    {:ok, _} = World.tool_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), r)
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [], @box)
  defp cell(row), do: row.micro |> Tuple.to_list() |> Enum.map(&div(&1, 8)) |> List.to_tuple()
  defp macros(s), do: for({_, r} <- s.damage, r.granularity == 0, into: %{}, do: {cell(r), r})

  # 每次手动提交后取样：各宏格首次被看到燃烧的时刻、消失时刻、峰值温度、是否越过热阻，以及首次转化时刻。
  # 后台 500 ms 定时提交会插在两次取样之间（大场景里一次取样可跨数秒模拟时间），所以取样时刻只用于"不晚于"一类的判定
  # （滞后只会让判定更严）；燃期由燃料账核对，不由取样时刻相减。温度峰值在两次取样间变化远小于 1 K（宏格热时间常数约百秒）。
  defp run(c, w, stop?, limit), do: run(c, w, stop?, limit, start_acc(observe(w)))

  # 已在燃烧的格（K 点燃）按点火时刻记，不按其后第一笔提交。
  defp start_acc(s) do
    lit = for {p, r} <- macros(s), Map.get(r, :burning, false), into: %{}, do: {p, s.thermal.elapsed_s}
    %{lit: lit, gone: %{}, peak: %{}, material: %{}, over: [], converted: nil}
  end

  defp run(c, w, stop?, limit, acc) do
    send(w, :thermal_commit)
    s = observe(w)
    t = s.thermal.elapsed_s
    now = macros(s)
    acc =
      Enum.reduce(now, acc, fn {p, r}, acc ->
        temperature = Map.get(r, :temperature_kelvin, c.ambient)
        acc
        |> update_in([:peak], &Map.update(&1, p, temperature, fn v -> max(v, temperature) end))
        |> update_in([:material], &Map.put(&1, p, r.material))
        |> update_in([:lit], &(if Map.get(r, :burning, false), do: Map.put_new(&1, p, t), else: &1))
        |> update_in([:over], &(if temperature >= c.materials[r.material]["heat_resistance_kelvin"], do: [{p, t} | &1], else: &1))
      end)
    gone = for p <- Map.keys(acc.material), not Map.has_key?(now, p), not Map.has_key?(acc.gone, p), into: %{}, do: {p, t}
    acc = %{acc | gone: Map.merge(acc.gone, gone)}
    acc = if acc.converted == nil and Map.has_key?(s.thermal, :transform_units), do: %{acc | converted: t}, else: acc
    if stop?.(s, acc) or t >= limit, do: {s, acc}, else: run(c, w, stop?, limit, acc)
  end

  defp settled(s, _), do: not s.thermal.active

  # 显热账：带温度宏格 C·(T − 环境) = 供热 + 环境交换 − 移除 − 反应吸热；燃料账：初始化 = 燃烧 + 弃置 + 还原剂 + 余量。
  defp assert_ledgers(c, s) do
    sensible = for {_, r} <- s.damage, r.granularity == 0, Map.has_key?(r, :temperature_kelvin), reduce: 0.0,
      do: (sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] * (r.temperature_kelvin - c.ambient))
    ledger = s.thermal.supplied_j + s.thermal.environment_j - Map.get(s.thermal, :removed_j, 0.0) -
      Map.get(s.thermal, :transform_j, 0.0)
    assert_in_delta sensible, ledger, 1.0e-6 * s.thermal.supplied_j
    left = for {_, r} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(r, :remaining_fuel_j, 0.0))
    assert_in_delta s.thermal.fuel_initialized_j, s.thermal.combustion_j + Map.get(s.thermal, :discarded_fuel_j, 0.0) +
      Map.get(s.thermal, :transform_reductant_fuel_j, 0.0) + left, 1.0e-6 * s.thermal.fuel_initialized_j
  end

  defp ground(xs, zs, material, y \\ 0), do: for(x <- xs, z <- zs, do: {{x, y, z}, material})
  defp burn_s(c, m), do: c.materials[m]["fuel_energy_per_macro_j"] / c.materials[m]["burn_power_per_macro_w"]

  test "夹具即 UE 发布字节，热环境为 Test-only 辐射环境", c do
    assert Base.encode16(:crypto.hash(:sha256, File.read!(c.path)), case: :lower) == @digest
    assert c.env["emissivity"] == 0.9 and c.env["classification"] == "Test-only"
    assert burn_s(c, @wood) == 120.0
  end

  test "露天相邻两块木头：K 点燃一块，60 s 内引燃另一块；各自按燃料烧满 fuel/P 后移除，无热毁", c do
    w = start(c, :pair, [@wood])
    {:ok, _} = World.apply_edits(w, ground(0..5, 0..4, @grass) ++ [{{2, 1, 2}, @wood}, {{3, 1, 2}, @wood}])
    ignite(w, {2.5, 4.5, 2.5}, {0.0, -1.0, 0.0}, 1)
    lit = macros(observe(w))[{2, 1, 2}]
    # 点火温度 = 环境 + 3.125 MJ / 6200 J/K = 797.19 K，高于 573.15 K 点火点。
    assert_in_delta lit.temperature_kelvin, c.ambient + c.tools[9]["heat_energy_j"] / c.materials[@wood]["heat_capacity_per_macro"], 1.0e-9
    assert lit.burning
    {s, acc} = run(c, w, &settled/2, 7200)
    refute s.thermal.active
    assert acc.lit[{3, 1, 2}] - acc.lit[{2, 1, 2}] <= 60.0
    # 两块都烧尽且全部化学燃料化为燃烧热、没有因热毁而弃置（弃置只剩燃尽阈值级的舍入）：即各自按 fuel/P = 120 s 燃尽。
    assert Map.has_key?(acc.gone, {2, 1, 2}) and Map.has_key?(acc.gone, {3, 1, 2})
    assert Map.get(s.thermal, :discarded_fuel_j, 0.0) < 1.0
    assert_in_delta s.thermal.combustion_j, 2 * c.materials[@wood]["fuel_energy_per_macro_j"], 1.0e-3
    assert acc.over == []
    assert_ledgers(c, s)
  end

  describe "石炉炼铜" do
    # 只测试：3×3 煤环 + 中心铜矿 + 矿上煤盖，放在石地上；炉 = 5³ 石壳，门在 +x 面 (4,1,2)。九块煤各按两次 K 越过点火点。
    @pile (for x <- 1..3, z <- 1..3, {x, z} != {2, 2}, do: {{x, 1, z}, 15}) ++ [{{2, 1, 2}, 16}, {{2, 2, 2}, 15}]
    @walls for x <- 0..4, y <- 1..4, z <- 0..4, not (x in 1..3 and y in 1..3 and z in 1..3), {x, y, z} != {4, 1, 2}, do: {{x, y, z}, 11}

    defp pile(c, name, walls) do
      w = start(c, name, [@stone, @ore])
      {:ok, _} = World.apply_edits(w, ground(0..4, 0..4, @stone) ++ @pile)
      coal = for {p, 15} <- @pile, do: p
      for {{x, _, z}, i} <- Enum.with_index(coal), press <- 0..1,
        do: ignite(w, {x + 0.5, 4.5, z + 0.5}, {0.0, -1.0, 0.0}, i * 2 + press + 1)
      if walls, do: {:ok, _} = World.apply_edits(w, @walls)
      w
    end

    test "露天煤堆里的矿石比转化温度低至少 100 K，不转化；同一堆在石炉里炼成铜，炉体与铜都不被热毁", c do
      ore = c.materials[@ore]
      x = ore["transform_kelvin"]

      open = pile(c, :open, false)
      {settled_open, open_acc} = run(c, open, &settled/2, 20_000)
      refute settled_open.thermal.active
      assert open_acc.converted == nil
      assert open_acc.material[{2, 1, 2}] == @ore
      assert open_acc.peak[{2, 1, 2}] <= x - 100.0
      assert Map.get(settled_open.thermal, :discarded_fuel_j, 0.0) < 1.0
      assert open_acc.over == []
      assert_ledgers(c, settled_open)

      furnace = pile(c, :furnace, true)
      {settled_furnace, acc} = run(c, furnace, &settled/2, 20_000)
      refute settled_furnace.thermal.active
      assert acc.converted != nil
      assert acc.material[{2, 1, 2}] == @copper
      # 一宏格矿 = 512 微格 × 单位；消耗还原剂化学燃料 = 比例 × 煤的每 m³ 燃料。
      assert settled_furnace.thermal.transform_units == 512 * c.units
      assert_in_delta settled_furnace.thermal.transform_reductant_fuel_j,
        ore["transform_reductant_units_per_unit"] * c.materials[@coal]["fuel_energy_per_macro_j"], 1.0e-3
      # 设计要求：一炉冶炼不烧毁石壳、地面和产出的铜；没有任何格越过自身热阻；煤只因燃尽而消失。
      stone = for {p, @stone} <- acc.material, do: p
      assert Enum.filter(stone, &Map.has_key?(acc.gone, &1)) == []
      refute Map.has_key?(acc.gone, {2, 1, 2})
      assert acc.over == []
      assert Map.get(settled_furnace.thermal, :discarded_fuel_j, 0.0) < 1.0
      assert_ledgers(c, settled_furnace)
      IO.puts("FIRE_FURNACE open_ore_peak=#{open_acc.peak[{2, 1, 2}]} x=#{x} converted_at=#{acc.converted} " <>
        "copper_peak=#{acc.peak[{2, 1, 2}]} wall_peak=#{acc.peak |> Map.take(stone) |> Map.values() |> Enum.max()}")
    end
  end

  # K 从 +x 侧点燃木柴层的边中格 (3,1,2) 或角格 (3,1,1)；两处都须把整张煤床引燃（石地上，炉膛地面同材料）。
  for {name, z} <- [edge: 2.5, corner: 1.5] do
    test "一层木柴铺在 3×3 煤床下，从#{name}点一块木柴：木柴层与整张煤床都烧起来，都按燃料燃尽", c do
      kindling = for x <- 1..3, z <- 1..3, do: {{x, 1, z}, @wood}
      bed = for x <- 1..3, z <- 1..3, do: {{x, 2, z}, @coal}
      w = start(c, :kindling, [@stone, @wood])
      {:ok, _} = World.apply_edits(w, ground(0..4, 0..4, @stone) ++ kindling ++ bed)
      ignite(w, {6.0, 1.5, unquote(z)}, {-1.0, 0.0, 0.0}, 1)
      {s, acc} = run(c, w, &settled/2, 30_000)
      refute s.thermal.active
      for {p, _} <- kindling ++ bed, do: assert(Map.has_key?(acc.lit, p), "#{inspect(p)} never lit")
      # 木柴与煤都烧尽，化学燃料全部化为燃烧热，无热毁弃置（煤名义燃期 fuel/P = 2000 s）。
      for {p, _} <- kindling ++ bed, do: assert(Map.has_key?(acc.gone, p))
      assert Map.get(s.thermal, :discarded_fuel_j, 0.0) < 1.0
      assert_in_delta s.thermal.combustion_j, 9 * (c.materials[@wood]["fuel_energy_per_macro_j"] +
        c.materials[@coal]["fuel_energy_per_macro_j"]), 1.0e-2
      assert acc.over == []
      assert_ledgers(c, s)
      IO.puts("FIRE_KINDLING #{unquote(name)} bed_lit=#{inspect(bed |> Enum.map(&acc.lit[elem(&1, 0)]) |> Enum.sort())} settled_at=#{s.thermal.elapsed_s}")
    end
  end

  test "整座木屋烧光后自行平息：每块木头都按燃料燃尽，无热毁，地面不毁，活动集清空", c do
    # 7×4×7 木屋：四面墙与屋顶一格厚，门 1×2、窗 1 格；地面草地。K 从屋外点燃门边墙根。
    house = for x <- 0..6, y <- 1..4, z <- 0..6, x in [0, 6] or z in [0, 6] or y == 4,
      {x, y, z} not in [{3, 1, 0}, {3, 2, 0}, {6, 2, 3}], do: {{x, y, z}, @wood}
    w = start(c, :house, [@wood])
    {:ok, _} = World.apply_edits(w, ground(-1..7, -1..7, @grass) ++ house)
    ignite(w, {6.5, 1.5, -4.0}, {0.0, 0.0, 1.0}, 1)
    {s, acc} = run(c, w, &settled/2, 30_000)
    refute s.thermal.active
    for {p, _} <- house, do: assert(Map.has_key?(acc.lit, p) and Map.has_key?(acc.gone, p), "#{inspect(p)}")
    assert Map.get(s.thermal, :discarded_fuel_j, 0.0) < 1.0
    assert_in_delta s.thermal.combustion_j, length(house) * c.materials[@wood]["fuel_energy_per_macro_j"], 1.0e-2
    assert Enum.filter(acc.gone, fn {p, _} -> acc.material[p] == @grass end) == []
    assert acc.over == []
    assert_ledgers(c, s)
    IO.puts("FIRE_HOUSE cells=#{length(house)} last_lit=#{acc.lit |> Map.values() |> Enum.max()} " <>
      "last_gone=#{acc.gone |> Map.values() |> Enum.max()} settled_at=#{s.thermal.elapsed_s}")
  end
end
