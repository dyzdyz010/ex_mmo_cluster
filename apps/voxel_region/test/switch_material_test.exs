defmodule VoxelRegion.SwitchMaterialTest do
  @moduledoc """
  只测试：R8-04 增量 2（器件材料化第二步，Voxim Docs/R8/Design-decisions.md §10 D6–D8）在 UE 发布的目录字节上核对。

  目录 `0c67824f…` = `DA_MaterialCoverageV1` 的发布字节：开关材料 41（闭合时 σ 同铜、断开绝缘，缺省断开；配方 8192 铜 + 4096 石 →
  4096 开关），撤下设备工具 4（开关）、5（灯）、6（加热器）、16（冷板），迁移映射 4 → 41、5/6 → 40、16 → 24。
  迁移起点是上一份发布 `0b2bb0b6…`（仍有这四种设备工具）。热环境 = 生产 ε 0.9（`environment-radiation.json`）。

  场景地形只经作者编辑入口；材料只经 material_supply；合成、放置、切换、挖掘都走正式生产／附件／工具意图；目录经在线参数发布。
  期望来自目录算术（配方数量、每宏格单位、r = d/(σA)）、账目恒等式与设计映射，不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :switch_material
  alias VoxelRegion.{World, Damage, ParameterEvolution}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}
  alias MmoContracts.Voxel.Codec

  @digest "0c67824f97992de46ea7306b3e7596b6b29eea3d51e4e2a226bf947b2cf21552"
  @previous "0b2bb0b6e47e5fe52aa4393f9e8eaae7f68aac7cd42af01f8269df89a725f172"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @stone 11
  @coal 15
  @copper 24
  @alloy 40
  @switch 41
  @macro 512 * 4096
  @materials [@stone, @coal, @copper, @alloy, @switch]

  setup do
    root = Path.join(System.tmp_dir!(), "switch_material_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @digest <> ".json")))
    %{root: root, data: data, materials: Map.new(data["materials"], &{&1["material_id"], &1}),
      tools: Map.new(data["tools"], &{&1["tool_id"], &1}), section: data["attachments"]["line_section_m2"]}
  end

  defp start(c, name, digest \\ @digest) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    unless File.exists?(catalog), do: File.cp!(Path.join(@fixtures, digest <> ".json"), catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, production_materials: @materials]}, id: name)
    {w, root}
  end

  defp restart(c, name) do
    :ok = stop_supervised(name)
    elem(start(c, name), 0)
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp stamp(a, seq), do: Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()})
  defp balance(w, material), do: Enum.find(World.material_balances(w, 1001), &(&1.material == material)).balance
  defp balances(w), do: Map.new(@materials, &{&1, balance(w, &1)})
  defp observe(w, box \\ {{-2, -2, -2}, {2, 2, 2}}), do: VoxelRegion.TestSupport.observe(w, [1001], box)

  defp craft(w, a, material) do
    seq = next()
    World.production_intent(w, stamp(a, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1,
      action: 4, coord: {0, 0, 0}, tool_id: 1, material: material})
  end

  # 面附件（面轴 y）贴在宿主格顶面，锚点是微格坐标。
  defp face(w, a, anchor, material) do
    seq = next()
    World.attachment_intent(w, a, %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0,
      kind: 0, axis: 1, size: 8, anchor: anchor, id: 0, material: material, tool_id: 1})
  end

  # 正式工具路径：先按眼睛到目标微格的射线查询命中身份，再以同一身份执行。
  defp use_tool(w, a, {x, y, z} = micro, tool, opts \\ []) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: Keyword.get(opts, :granularity, 0),
      incarnation: 0, owner: {0, 0}, material: 0}
    q = Map.merge(q, Map.new(Keyword.get(opts, :target, [])))
    target = if q.granularity == 3, do: q, else: elem(World.tool_intent(w, a, q), 1)
    r = Map.merge(q, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    World.tool_intent(w, stamp(a, seq), %{r | action: Keyword.get(opts, :action, 1)})
  end

  test "夹具即 UE 发布字节：开关材料、配方与退役映射按作者值发布；上一份发布可在线升级到它", c do
    path = Path.join(@fixtures, @digest <> ".json")
    assert Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) == @digest
    s = c.materials[@switch]
    assert {s["circuit_switch"], s["electrical_conductivity"], s["recipe_units"]} == {true, c.materials[@copper]["electrical_conductivity"], 4096}
    assert s["recipe_inputs"] == [%{"material_id" => @copper, "units" => 8192}, %{"material_id" => @stone, "units" => 4096}]
    # 一份配方 = 一个微格 = 一块宏面的量：4096 = 每微格单位 = 每宏格单位 × 面厚 × 8。
    assert s["recipe_units"] == c.data["attachments"]["material_units_per_micro"]
    assert s["recipe_units"] == round(512 * 4096 * c.data["attachments"]["face_thickness_m"])
    assert c.data["retired_tools"] == [%{"tool_id" => 4, "material_id" => 41}, %{"tool_id" => 5, "material_id" => 40},
      %{"tool_id" => 6, "material_id" => 40}, %{"tool_id" => 16, "material_id" => 24}]
    assert Enum.all?([4, 5, 6, 16], &(not Map.has_key?(c.tools, &1)))
    old = Damage.load(Path.join(@fixtures, @previous <> ".json"))
    new = Damage.load(path)
    assert ParameterEvolution.compatible?(old, new)
    # 反例：撤下工具却不在 retired_tools 里，不能在线发布。
    refute ParameterEvolution.compatible?(old, %{new | retired: Map.delete(new.retired, 16)})
  end

  test "合成：输入全部足额才整笔扣减、产物入库，合成账记净变化；材料不足或无配方整笔拒绝；重启恢复", c do
    {w, _} = start(c, :craft)
    a = actor({0.5, 3.5, 0.5})
    # 两份铜多 4095 单位、三份石：第三次合成恰好差 1 单位铜。
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@copper => 2 * 8192 + 8191, @stone => 3 * 4096})
    before = balances(w)
    assert {:ok, s1} = craft(w, a, @switch)
    assert {:ok, s2} = craft(w, a, @switch)
    assert s2 == s1 + 1
    after_two = balances(w)
    assert after_two == %{before | @copper => before[@copper] - 16384, @stone => before[@stone] - 8192, @switch => 8192}
    ledger = World.material_snapshot(w, [1001], []).craft_ledger
    assert ledger == %{@copper => -16384, @stone => -8192, @switch => 8192}
    # 守恒：各材料余额变化 = 合成账。
    assert Map.new(@materials, &{&1, after_two[&1] - before[&1]}) |> Map.reject(fn {_, d} -> d == 0 end) == ledger
    seq = World.seq(w)
    assert {:error, :insufficient_material} = craft(w, a, @switch)
    assert {:error, :unknown_recipe} = craft(w, a, @copper)
    assert World.seq(w) == seq
    assert balances(w) == after_two
    w = restart(c, :craft)
    assert balances(w) == after_two
    assert World.material_snapshot(w, [1001], []).craft_ledger == ledger
  end

  test "开关不可拆回：挖掉开关宏格、拆掉开关面都只返还开关单位，铜和石不变", c do
    {w, _} = start(c, :decompose)
    a = actor({1.5, 3.5, 1.5})
    {:ok, _} = World.apply_edits(w, for(x <- -1..3, z <- -1..3, do: {{x, 0, z}, @stone}))
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@switch => @macro + 4096})
    seq = next()
    {:ok, _} = World.production_intent(w, stamp(a, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1,
      action: 1, coord: {1, 1, 1}, tool_id: 1, material: @switch})
    {:ok, face_id} = face(w, a, {16, 8, 16}, @switch)
    assert balances(w) == %{@stone => 0, @coal => 0, @copper => 0, @alloy => 0, @switch => 0}
    # 开关面：F 拆卸整件，返还一块宏面的量 4096（眼睛在面的正上方，射线不擦过开关宏格）。
    assert {:ok, _} = use_tool(w, actor({2.5, 3.5, 2.5}), {16, 8, 16}, 1, action: 2, granularity: 3,
      target: [micro: {16, 8, 16}, incarnation: face_id, owner: {face_id, 1}, material: @switch])
    assert balances(w)[@switch] == 4096
    # 开关宏格：镐击到 HP 0，整格返还 512 × 4096。
    hits = ceil(c.materials[@switch]["max_hp_per_macro"] / (c.tools[1]["power"] - c.materials[@switch]["defense"]))
    for _ <- 1..hits, do: assert({:ok, _} = use_tool(w, a, {8, 8, 8}, 1))
    assert balances(w) == %{@stone => 0, @coal => 0, @copper => 0, @alloy => 0, @switch => 4096 + @macro}
  end

  # 回路（地面宏格 y = 0 为石；y = 1 一排：铜 C1 (0,1,0)、电阻合金 L (1,1,0)、铜 C2 (2,1,0)）。地面顶上三块面：
  # 铜面 F_a (x 0, z 1)、开关面 S (x 2, z 1)、铜面 F0 (x 1, z 2) 上装 24 V 源；源端口 (1,2)→(2,2)。
  # 端口 a 是 F_a 的角 → F_a 北沿 9 个点接 C1 → C1–L–C2 两个接触 → C2 接 S 北沿 → S 的角是端口 b。S 断开时端口 b 悬空。
  defp lamp_circuit(c, name) do
    {w, root} = start(c, name)
    a = actor({1.5, 3.5, 2.5})
    ground = for x <- -1..4, z <- -1..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{0, 1, 0}, @copper}, {{1, 1, 0}, @alloy}, {{2, 1, 0}, @copper}])
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{@copper => 2 * 4096, @switch => 4096, @coal => @macro})
    {:ok, fa} = face(w, a, {0, 8, 8}, @copper)
    {:ok, switch} = face(w, a, {16, 8, 8}, @switch)
    {:ok, source} = face(w, a, {8, 8, 16}, @copper)
    on_face = fn id, anchor, material -> [micro: anchor, incarnation: id, owner: {id, 1}, material: material] end
    {:ok, _} = use_tool(w, a, {8, 8, 16}, 3, granularity: 3, target: on_face.(source, {8, 8, 16}, @copper))
    {:ok, _} = use_tool(w, a, {8, 8, 16}, 8, granularity: 3, target: on_face.(source, {8, 8, 16}, @copper))
    toggle = fn -> use_tool(w, a, {16, 8, 8}, 7, granularity: 3, target: on_face.(switch, {16, 8, 8}, @switch)) end
    %{w: w, root: root, a: a, fa: fa, switch: switch, source: source, toggle: toggle}
  end

  defp commit(w) do
    send(w, :thermal_commit)
    observe(w)
  end

  defp source_row(s, id), do: s.damage[{3, id}].circuit
  defp lamp(s), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {8, 8, 0}))

  test "开关面缺省断开：源有能量也严格 0 A；闭合按手算电流点亮电阻合金，再断开熄灭；开合随日志恢复并下发 flags 位 2", c do
    %{w: w, switch: switch, source: source, toggle: toggle} = lamp_circuit(c, :lamp)
    open = commit(w)
    assert source_row(open, source).current_a == 0.0
    assert source_row(open, source).remaining_j == c.tools[8]["circuit_energy_j"]
    refute Map.has_key?(lamp(open) || %{}, :electric_w)
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(w, {{0, 0, 0}, {1, 1, 1}}, self(), ref, false)
    assert_receive {:canonical_snapshot, ^ref, _}
    {:ok, toggled} = toggle.()
    # 复制：同一事务号的增量带闭合的开关整件行，编码后 flags 位 2 置位。
    assert_receive {:canonical_delta, %{transaction_seq: ^toggled, transaction: %{property_states: [row]}}}, 5_000
    assert {row.granularity, row.incarnation, row.material, row.closed} == {3, switch, @switch, true}
    # 属性批次里的记录没有请求号；客户端对非 0 请求号拒收整帧（switch-02 实跑：切换后会话 protocol decode 失败）。
    assert row.request_id == 0
    {:ok, bytes} = Codec.encode({:voxel_property_state, row})
    assert Bitwise.band(:binary.at(IO.iodata_to_binary(bytes), 120), 4) == 4
    lit = Enum.reduce(1..3, nil, fn _, _ -> commit(w) end)
    # 手算：R = 源内阻 1 Ω + 两个铜—合金接触各 (1/σ_Cu + 1/σ_A)/2/1 m²（合金一侧 0.125 Ω）
    #   + 两侧“面网格 + 宿主半格”，每侧上界 = 8 条棱 × 2/(σ_Cu·面厚) + 一个宿主半格 1/2/(σ_Cu·线截面)（并联只会更小）；
    # 下界另扣合金经 F_a、S 角点的宿主半格 1/2/(σ_A·线截面) ≈ 3.3e4 Ω 并联旁路（相对 < 1e-5）。
    sigma_cu = c.materials[@copper]["electrical_conductivity"]
    sigma_a = c.materials[@alloy]["electrical_conductivity"]
    contacts = 2 * (1 / sigma_cu + 1 / sigma_a) / 2
    side = 8 * 2 / (sigma_cu * c.data["attachments"]["face_thickness_m"]) + 0.5 / (sigma_cu * c.section)
    r_min = (1 + contacts) * (1 - 1.0e-5)
    r_max = 1 + contacts + 2 * side
    i = source_row(lit, source).current_a
    assert i >= 24 / r_max and i <= 24 / r_min
    # 电阻合金整格：两条接触边里合金一侧的份额 = I² × 2 × 0.125 Ω（铜侧份额 ~1e-8 相对）。
    joule = i * i * 2 * (1 / sigma_a) / 2
    assert_in_delta lamp(lit).electric_w, joule, 1.0e-4 * joule
    later = commit(w)
    dt = later.thermal.elapsed_s - lit.thermal.elapsed_s
    assert_in_delta later.thermal.circuit_light_j - lit.thermal.circuit_light_j, 0.2 * joule * dt, 1.0e-3 * joule * dt
    IO.puts("SWITCH_LAMP current=#{i} bounds=[#{24 / r_max},#{24 / r_min}] lamp_w=#{lamp(lit).electric_w} light_w=#{0.2 * lamp(lit).electric_w}")
    # 重启：闭合状态与电源余量从日志恢复，恢复后照常供电。
    closed = observe(w)
    w = restart(c, :lamp)
    restored = observe(w)
    assert restored.damage[{3, switch}].closed
    assert restored.damage[{3, switch}] == closed.damage[{3, switch}]
    assert source_row(restored, source).remaining_j == source_row(closed, source).remaining_j
    assert source_row(commit(w), source).current_a > 19.0
    # 断开：同一回路再次严格开路，合金行去掉电功率。
    a = actor({1.5, 3.5, 2.5})
    {:ok, _} = use_tool(w, a, {16, 8, 8}, 7, granularity: 3,
      target: [micro: {16, 8, 8}, incarnation: switch, owner: {switch, 1}, material: @switch])
    dark = commit(w)
    assert source_row(dark, source).current_a == 0.0
    refute Map.has_key?(lamp(dark), :electric_w)
    refute dark.damage[{3, switch}].closed
  end

  test "开关宏格与电源在同一目录下：非开关材料不能切换，切换只翻转命中的那一格", c do
    %{w: w, a: a, fa: fa} = lamp_circuit(c, :targets)
    {:ok, _} = World.material_supply(w, 1001, "switch", %{@switch => 2 * @macro})
    for {coord, seq} <- [{{0, 2, 0}, next()}, {{2, 2, 0}, next()}] do
      {:ok, _} = World.production_intent(w, stamp(a, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1,
        action: 1, coord: coord, tool_id: 1, material: @switch})
    end
    assert {:error, :not_a_switch} = use_tool(w, a, {0, 8, 8}, 7, granularity: 3,
      target: [micro: {0, 8, 8}, incarnation: fa, owner: {fa, 1}, material: @copper])
    b = actor({0.5, 4.5, 0.5})
    assert {:ok, _} = use_tool(w, b, {4, 16, 4}, 7)
    s = observe(w)
    cells = for {_, %{granularity: 0, material: @switch} = t} <- s.damage, into: %{}, do: {t.micro, Map.get(t, :closed, false)}
    assert cells[{0, 16, 0}] == true
    refute Map.get(cells, {16, 16, 0}, false)
  end

  describe "目录发布迁移（D8）" do
    # 纯函数：构造的设备行与逐槽热行（夹具，非世界真值）按目录映射迁移；期望逐项手算。
    test "retire_devices：开关保持开合、灯／加热器变电阻合金、冷板变铜，电源不动；槽行换材料键、HP 按每宏格 HP 之比、热容差计入重标账" do
      mat = fn hp, cap, extra -> Map.merge(%{"max_hp_per_macro" => hp, "heat_capacity_per_macro" => cap}, extra) end
      # 附件规格与发布目录同口径：每微格 4096 单位、面厚 1/512 m → 每槽 64 单位 = 1/64 m² × 1/512 m。
      old = %{materials: %{24 => mat.(100, 34500.0, %{})}, attachments: %{"material_units_per_micro" => 4096, "face_units" => 64}}
      new = %{materials: %{24 => mat.(100, 34500.0, %{}), 40 => mat.(50, 40000.0, %{}), 41 => mat.(100, 34500.0, %{"circuit_switch" => true})},
        retired: %{4 => 41, 5 => 40, 16 => 24}}
      device = fn id, tool, closed ->
        slot = {0, 1, {id * 8, 8, 0}}
        row = VoxelRegion.Attachments.identity(slot, {id, 24})
          |> Map.merge(%{flags: 0, hp: 10.0, max_hp: 12.5, circuit: %{tool_id: tool, closed: closed, remaining_j: 0.0}})
        {{3, id}, row}
      end
      hot = VoxelRegion.Attachments.identity({0, 1, {16, 8, 0}}, {2, 24})
        |> Map.merge(%{granularity: 4, flags: 0, hp: 0.2, max_hp: 0.2, temperature_kelvin: 393.15})
      damage = Map.new([device.(1, 4, false), device.(2, 5, true), device.(3, 16, true), device.(4, 3, true), {Damage.key(hot), hot}])
      attachments = Map.new(for id <- 1..4, do: {{0, 1, {id * 8, 8, 0}}, {id, 24}})
      thermal = %{config: %{"ambient_kelvin" => 293.15}}
      m = ParameterEvolution.retire_devices(damage, attachments, thermal, old, new)
      assert Map.drop(m.damage[{3, 1}], [:closed]) == Map.drop(damage[{3, 1}], [:circuit]) |> Map.put(:material, 41)
      assert m.damage[{3, 1}].closed == false
      assert m.damage[{3, 2}] == %{Map.drop(damage[{3, 2}], [:circuit]) | material: 40, hp: 5.0, max_hp: 6.25}
      refute Map.has_key?(m.damage[{3, 2}], :closed)
      assert m.damage[{3, 3}] == %{Map.drop(damage[{3, 3}], [:circuit]) | material: 24}
      assert m.damage[{3, 4}] == damage[{3, 4}]
      moved = %{hot | material: 40, hp: 0.1, max_hp: 0.1}
      assert m.damage[Damage.key(moved)] == moved
      refute Map.has_key?(m.damage, Damage.key(hot))
      assert m.tombstones == [hot]
      # 槽体积 = 1/64 m² × 面厚；重标 = 体积 × (40000 − 34500) × 100 K。
      assert_in_delta m.thermal.parameter_rebase_j, 1 / 64 / 512 * 5500 * 100, 1.0e-9
      assert Enum.sort(m.slots) == Enum.sort(for id <- 1..3, do: {0, 1, {id * 8, 8, 0}})
      assert m.attachments == %{attachments | {0, 1, {8, 8, 0}} => {1, 41}, {0, 1, {16, 8, 0}} => {2, 40}, {0, 1, {24, 8, 0}} => {3, 24}}
    end

    # 旧目录上的开关设备装上即闭合；增量 2 起切换工具只翻转开关材料，世界里造不出断开的开关设备，断开的映射由上面的纯函数测试覆盖。
    test "世界：旧目录上的开关、灯、加热器、冷板与电源经一次参数发布迁移；附件载荷、订阅与重启一致；退役工具不可再用", c do
      old_root = Path.join(c.root, "migrate")
      File.mkdir_p!(old_root)
      File.cp!(Path.join(@fixtures, @previous <> ".json"), Path.join(old_root, "properties.json"))
      {w, root} = start(c, :migrate, @previous)
      a = actor({3.5, 3.5, 1.5})
      {:ok, _} = World.apply_edits(w, for(x <- -1..7, z <- -1..3, do: {{x, 0, z}, @stone}))
      {:ok, _} = World.material_supply(w, 1001, "fixture", %{@copper => 6 * 4096, @coal => @macro})
      installs = [switch: 4, lamp: 5, heater: 6, cold: 16, source: 3]
      faces = for {{name, tool}, x} <- Enum.with_index(installs), into: %{} do
        anchor = {x * 8, 8, 8}
        {:ok, id} = face(w, a, anchor, @copper)
        target = [micro: anchor, incarnation: id, owner: {id, 1}, material: @copper]
        {:ok, _} = use_tool(w, a, anchor, tool, granularity: 3, target: target)
        {name, {id, anchor}}
      end
      {switch_id, switch_anchor} = faces.switch
      {source_id, source_anchor} = faces.source
      {:ok, _} = use_tool(w, a, source_anchor, 8, granularity: 3,
        target: [micro: source_anchor, incarnation: source_id, owner: {source_id, 1}, material: @copper])
      box = {{-1, -1, -1}, {1, 1, 1}}
      before = observe(w, box)
      assert before.damage[{3, switch_id}].circuit.closed == true
      ref = make_ref()
      :ok = World.canonical_snapshot_and_subscribe(w, {{0, 0, 0}, {1, 1, 1}}, self(), ref, false)
      assert_receive {:canonical_snapshot, ^ref, _}
      assert :ok = World.publish_parameters(w, Path.join(@fixtures, @digest <> ".json"), before.property_digest)
      after_state = observe(w, box)
      assert after_state.seq == before.seq + 1
      assert after_state.property_digest == Damage.load(Path.join(@fixtures, @digest <> ".json")).digest
      expected = %{switch: {@switch, true}, lamp: {@alloy, nil}, heater: {@alloy, nil}, cold: {@copper, nil}}
      for {name, {material, closed}} <- expected do
        {id, _} = faces[name]
        row = after_state.damage[{3, id}]
        assert {row.material, Map.get(row, :closed), Map.has_key?(row, :circuit)} == {material, closed, false}, "#{name}"
      end
      assert after_state.damage[{3, source_id}].circuit.tool_id == 3
      assert after_state.damage[{3, source_id}].circuit.remaining_j == before.damage[{3, source_id}].circuit.remaining_j
      # 附件真值：区域载荷里这些面的槽已换成映射材料（客户端据此重画）。
      slots = VoxelRegion.TestSupport.payload(w, 0, {0, 0, 0}).attachments
      for {name, {material, _}} <- expected do
        {id, anchor} = faces[name]
        assert slots[{0, 1, anchor}] == {id, material}, "#{name}"
      end
      # 同一事务：订阅者收到带附件区域 afterimage 与迁移后属性行的一笔增量。
      assert_receive {:canonical_delta, %{transaction_seq: seq, transaction: txn}}, 5_000
      assert seq == after_state.seq
      migrated = for %{granularity: 3} = r <- txn.property_states, into: %{}, do: {r.incarnation, r}
      assert migrated[switch_id].material == @switch and migrated[switch_id].closed == true
      {lamp_id, _} = faces.lamp
      assert migrated[lamp_id].material == @alloy and not Map.has_key?(migrated[lamp_id], :circuit)
      # 退役工具不再是工具；迁移后的开关按材料切换。
      {_, lamp_anchor} = faces.lamp
      assert {:error, :invalid_tool} = use_tool(w, a, lamp_anchor, 5, granularity: 3,
        target: [micro: lamp_anchor, incarnation: lamp_id, owner: {lamp_id, 1}, material: @alloy])
      assert {:ok, _} = use_tool(w, a, switch_anchor, 7, granularity: 3,
        target: [micro: switch_anchor, incarnation: switch_id, owner: {switch_id, 1}, material: @switch])
      toggled = observe(w, box)
      assert toggled.damage[{3, switch_id}].closed == false
      # 重启：新目录路径（部署时替换的文件）加日志恢复出同一状态。
      File.cp!(Path.join(@fixtures, @digest <> ".json"), Path.join(root, "properties.json"))
      w = restart(c, :migrate)
      restored = observe(w, box)
      assert restored.damage == toggled.damage
      assert restored.thermal == toggled.thermal
      assert VoxelRegion.TestSupport.payload(w, 0, {0, 0, 0}).attachments == slots
    end
  end
end
