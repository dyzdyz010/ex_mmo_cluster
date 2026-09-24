defmodule VoxelRegion.DeviceMaterialProductionTest do
  @moduledoc """
  只测试：R8-04 增量 1（器件材料化第一步）在 UE 发布的目录字节上核对，增量 2 起用 `0c67824f…`（DA_MaterialCoverageV1：
  开关材料 41、撤下开关／灯／加热器／冷板设备工具）与生产热环境（ε 0.9，数值与 `environment-radiation.json` 相同）。
  电阻合金 40：σ 4 S/m、λ 0.2、C 40 kJ/(m³K)、k 25、耐热 1900 K；铁矿石 17 在 1373.15 K 接触煤时单向转化成 40。

  场景经作者编辑入口 / place_prefab 一次建立；面、电源、投料、开关切换都走正式附件与工具入口；时间只经 :thermal_commit 推进。
  开关是回程微格线里的一格开关材料（缺省断开），代替原来装在北面的开关设备。
  期望来自目录算术（r = d/(σA)，接触边两侧各半格；I = V / ΣR；光 = λ × 焦耳）或设计阈值（付费电能耗尽前点燃木头），
  不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :device_material
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.Actor

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
  @wood 19
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
      units: data["attachments"]["material_units_per_micro"], section: data["attachments"]["line_section_m2"]}
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
      production_materials: [@stone, @coal, @iron_ore, @wood, @copper, @alloy, @switch]]}, id: name)
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@coal => 10_000_000, @copper => 10_000_000})
    {w, prefabs}
  end

  # 微格 prefab（VXPD v1，格按坐标排序）锚在 anchor（微格坐标）。
  defp place_micro(w, prefabs, anchor, cells) do
    cells = Enum.sort(cells)
    body = for {{x, y, z}, m} <- cells, into: <<>>, do: <<x::signed-little-32, y::signed-little-32, z::signed-little-32, m::16-little>>
    bytes = <<"VXPD", 1::32-little, length(cells)::32-little>> <> body <> <<0::32-little>>
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(prefabs, Base.encode16(id) <> ".vxpd"), bytes)
    :ok = World.publish_prefabs(w, prefabs)
    {:ok, _} = World.place_prefab(w, id, anchor, 0)
  end

  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  # 在块的西面（轴 0）铺一块 8×8 铜面装源：下端口在西北下角，上端口在西北上角（落在顶线的第一格铜上）。
  # 回路由 prefab 里的回程微格线闭合：它沿块北侧底边 (x, 8, 15) 从下行铜柱底回到下端口，其中一格是开关材料。
  defp devices(w, a, corner, source_tool, seq0) do
    face = %{request_id: seq0, client_intent_seq: seq0, logical_scene_id: 1, action: 0, kind: 0, axis: 0, size: 8,
      anchor: corner, id: 0, material: @copper, tool_id: 1}
    {:ok, id} = World.attachment_intent(w, a, face)
    source = {id, 0, corner}
    use = fn {id, axis, anchor}, tool, seq ->
      r = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, tool_id: tool, direction: {1.0, 0.0, 0.0},
        micro: anchor, granularity: 3, incarnation: id, owner: {id, axis}, material: @copper}
      {:ok, _} = World.tool_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), r)
    end
    use.(source, source_tool, seq0 + 10)
    use.(source, 8, seq0 + 13)      # 投料两次
    use.(source, 8, seq0 + 14)
    %{toggle: fn {x, y, z} = switch, seq -> toggle(w, actor({(x + 0.5) / 8, (y + 0.5) / 8 + 1.5, (z + 0.5) / 8}), switch, seq) end}
  end

  # 正式工具路径切换开关微格：眼睛在开关正上方 1.5 m，先查询射线命中的构件身份，再以同一身份发切换工具 7。
  defp toggle(w, a, {x, y, z} = micro, seq) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 7, direction: {dx / n, dy / n, dz / n},
      micro: micro, granularity: 2, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, %{material: @switch, micro: ^micro} = t} = World.tool_intent(w, a, q)
    r = Map.merge(q, Map.take(t, [:granularity, :incarnation, :owner, :material]))
    {:ok, _} = World.tool_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), %{r | action: 1})
  end

  # 回程线：下行柱底 (8,0,0) 外侧一格 (8,0,−1)，沿 z = −1、y = 0 向 x = 0；x = 4 是开关材料（相对块锚点）。
  defp return_line, do: for(x <- 0..8, do: {{x, 0, -1}, if(x == 4, do: @switch, else: @copper)})

  defp observe(w, box), do: VoxelRegion.TestSupport.observe(w, [], box)
  defp row(s, micro), do: Enum.find(Map.values(s.damage), &(&1.micro == micro and &1.granularity in [0, 1]))
  defp commits(w, n, box), do: Enum.reduce(1..n, nil, fn _, _ -> send(w, :thermal_commit); observe(w, box) end)

  # 目录手算的串联电阻：源内阻 + 两个端口落在铜微格的宿主半格 + 铜—铜/铜—开关/铜—合金/合金—合金接触。
  defp copper_host(c), do: @micro / 2 / (c.materials[@copper]["electrical_conductivity"] * c.section)
  defp contact(c, a, b),
    do: (@micro / c.materials[a]["electrical_conductivity"] + @micro / c.materials[b]["electrical_conductivity"]) / 2 / @micro_area

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

  test "灯：石块上一条铜微格线中间一格电阻合金，24 V 源 + 回程线里一格开关材料；断开时 0 A，闭合按欧姆定律，灯丝得到自身 I²R，λ 份额记为光，再断开即熄", c do
    {w, prefabs} = start(c, :lamp)
    {:ok, _} = World.apply_edits(w, (for x <- 0..5, z <- 0..5, do: {{x, 0, z}, @stone}) ++ [{{2, 1, 2}, @stone}])
    # 石块 L 占微格 [16,24)×[8,16)×[16,24)。线：顶面北沿 (16..23,16,16)，拐角 (24,16,16)，东侧下行 (24,8..15,16)；灯丝在 (20,16,16)。
    top = for x <- 0..7, do: {{x, 8, 0}, if(x == 4, do: @alloy, else: @copper)}
    down = [{{8, 8, 0}, @copper}] ++ for(y <- 0..7, do: {{8, y, 0}, @copper})
    place_micro(w, prefabs, {16, 8, 16}, top ++ down ++ return_line())
    control = devices(w, actor({1.0, 1.6, 1.0}), {16, 8, 16}, 3, 10)
    switch = {20, 8, 15}
    box = {{0, 0, 0}, {6, 4, 6}}
    open = commits(w, 2, box)
    filament = {20, 16, 16}
    # 开关缺省断开：源有付费能源，回路严格开路。
    source = fn s -> Enum.find_value(s.damage, fn {_, %{granularity: 3, circuit: d}} -> d; _ -> nil end) end
    assert source.(open).current_a == 0.0
    refute Map.has_key?(row(open, filament) || %{}, :electric_w)
    control.toggle.(switch, 30)
    lit = commits(w, 4, box)
    assert Enum.find(Map.values(lit.damage), &(&1.micro == switch and &1.granularity == 1)).closed
    t = c.tools
    # 顶线 5、拐角两侧 2、下行 7 个铜—铜接触；回程线 1 + 3 + 3 个铜—铜与 2 个铜—开关（开关闭合时 σ 同铜）；2 个铜—合金；2 个宿主半格。
    r = t[3]["circuit_resistance_ohm"] + 2 * copper_host(c) +
      21 * contact(c, @copper, @copper) + 2 * contact(c, @copper, @switch) + 2 * contact(c, @copper, @alloy)
    current = t[3]["circuit_voltage_v"] / r
    devices = for {_, %{granularity: 3, circuit: d}} <- lit.damage, into: %{}, do: {d.tool_id, d}
    # 容差 1e-7 A（相对 1e-8）：少算或多算一个铜—铜接触（1.4e-7 Ω）会差 3.7e-7 A。
    assert_in_delta devices[3].current_a, current, 1.0e-7
    fil = row(lit, filament)
    # 灯丝的 I²R：两条铜—合金接触里它那一侧的份额 = I² × 2 × (1/8)/σ/2/A = I² × 2 Ω（铜侧份额 ~7e-8）。
    joule = current * current * 2 * (@micro / 4 / 2 / @micro_area)
    assert_in_delta fil.electric_w, joule, 1.0e-6 * joule
    assert_in_delta fil.current_a, current, 1.0e-7
    refute Map.has_key?(row(lit, {16, 16, 16}) || %{}, :electric_w)   # 铜不发光
    # 光账：之后一段时间里 circuit_light_j 的增量 = λ × 灯丝焦耳 × 模拟时长（铜 λ 0，源/开关工具光效 0）。
    later = commits(w, 6, box)
    dt = later.thermal.elapsed_s - lit.thermal.elapsed_s
    assert_in_delta later.thermal.circuit_light_j - lit.thermal.circuit_light_j, 0.2 * joule * dt, 1.0e-6 * joule * dt
    # 供电 = 热（各节点）+ 光：源 V·I 的斜率。
    assert_in_delta later.thermal.circuit_supplied_j - lit.thermal.circuit_supplied_j, t[3]["circuit_voltage_v"] * current * dt, 1.0e-6 * dt * 24 * current
    control.toggle.(switch, 31)
    dark = commits(w, 2, box)
    refute Map.has_key?(row(dark, filament), :electric_w)
    assert source.(dark).current_a == 0.0
    IO.puts("DEVICE_LAMP current=#{current} filament_w=#{fil.electric_w} light_w=#{0.2 * fil.electric_w} " <>
      "flux_w_m2=#{0.2 * fil.electric_w / (6 * @micro_area)} filament_k=#{later |> row(filament) |> Map.get(:temperature_kelvin)}")
  end

  test "发热板：木块顶面 8×6 电阻合金微格夹在两根铜排之间（1.5 Ω），480 V 源装在木块上、回程线里一格开关；闭合后付费电能耗尽前点燃木块", c do
    {w, prefabs} = start(c, :slab)
    {:ok, _} = World.apply_edits(w, (for x <- 0..6, z <- 0..6, do: {{x, 0, z}, @stone}) ++ [{{3, 1, 3}, @wood}])
    # HOST 占微格 [24,32)×[8,16)×[24,32)。板：y 16，x 24 与 31 为铜排，25..30 为合金；拐角 (32,16,24)，东侧下行 (32,8..15,24)。
    slab = for x <- 0..7, z <- 0..7, do: {{x, 8, z}, if(x in [0, 7], do: @copper, else: @alloy)}
    down = [{{8, 8, 0}, @copper}] ++ for(y <- 0..7, do: {{8, y, 0}, @copper})
    place_micro(w, prefabs, {24, 8, 24}, slab ++ down ++ return_line())
    control = devices(w, actor({2.0, 1.6, 2.0}), {24, 8, 24}, 19, 10)
    box = {{0, 0, 0}, {7, 4, 7}}
    control.toggle.({28, 8, 23}, 30)
    closed = commits(w, 1, box)
    t = c.tools
    # 每行：2 个铜—合金 + 5 个合金—合金接触 = 12 Ω；8 行并联 1.5 Ω。铜排、拐角、下行与宿主半格为 1e-4 Ω 量级，留 1e-3 相对容差。
    row_r = 2 * contact(c, @copper, @alloy) + 5 * contact(c, @alloy, @alloy)
    assert_in_delta row_r / 8, 1.5, 1.0e-6
    current = t[19]["circuit_voltage_v"] / (t[19]["circuit_resistance_ohm"] + row_r / 8)
    devices = for {_, %{granularity: 3, circuit: d}} <- closed.damage, into: %{}, do: {d.tool_id, d}
    assert_in_delta devices[19].current_a, current, 1.0e-3 * current
    paid_s = 2 * t[8]["circuit_energy_j"] / (t[19]["circuit_voltage_v"] * devices[19].current_a)
    host = {24, 8, 24}
    {lit_at, s} = Enum.reduce_while(1..4000, nil, fn _, _ ->
      send(w, :thermal_commit)
      s = observe(w, box)
      h = row(s, host)
      cond do
        h && Map.get(h, :burning, false) -> {:halt, {s.thermal.elapsed_s - closed.thermal.elapsed_s, s}}
        s.thermal.elapsed_s - closed.thermal.elapsed_s > paid_s + 60 -> {:halt, {nil, s}}
        true -> {:cont, nil}
      end
    end)
    slab_w = for {_, %{material: @alloy, electric_w: e}} <- s.damage, reduce: 0.0, do: (sum -> sum + e)
    IO.puts("DEVICE_SLAB current=#{devices[19].current_a} expected=#{current} slab_w=#{slab_w} paid_s=#{paid_s} host_lit_s=#{inspect(lit_at)}")
    assert lit_at != nil and lit_at <= paid_s
  end
end
