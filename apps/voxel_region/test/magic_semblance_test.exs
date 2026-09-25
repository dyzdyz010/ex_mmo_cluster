defmodule VoxelRegion.MagicSemblanceTest do
  @moduledoc """
  只测试：魔法增量 2 纯规则（目录、程序形态、拟态成本、运动学弹道、拟态作为热内核外部节点）。
  夹具 `fixtures/magic/1ff967d7….json` 是按契约 JSON 结构手写的 Test-only 目录（增量 1 内容 + `semblance` 段、
  `form.semblance` / `act.throw` / `act.dispel` 与三个预设；目录版本 2：姿态、构型损耗参数与最大输出功率），不是 UE 发布物；
  期望值全部手算（成本按前摇契约 §2 手算表），写在断言旁。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Semblance}

  @digest "1ff967d746cd0f1064924292011ce5227dcb6db03d99d45a9befa98a89908075"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)

  setup_all do
    %{catalog: Catalog.load(@path), data: Jason.decode!(File.read!(@path))}
  end

  defp preset(c, id), do: Enum.find(c.data["presets"], &(&1["id"] == id))["program"]
  defp form(args), do: %{"sym" => "form.semblance", "args" => args}
  defp toss(v), do: %{"sym" => "act.throw", "args" => %{"speed_mps" => v}}
  defp program(emit, steps), do: %{"v" => 1, "target" => %{"kind" => "aim"}, "emit" => emit, "steps" => steps}
  defp rel(actual, expected), do: assert(abs(actual - expected) <= 1.0e-6 * abs(expected), "#{actual} vs #{expected}")
  defp ball, do: %{"shape" => 0, "radius_m" => 0.25, "mass_kg" => 2, "temperature_k" => 2000, "glow_w" => 0, "lifetime_s" => 60}

  test "目录：拟态段与上限；枚举槽取整；含 form.semblance 却缺 semblance 段的目录不能加载", c do
    assert Base.encode16(c.catalog.digest, case: :lower) == @digest
    assert c.catalog.semblance == %{specific_heat: 500.0, conductivity: 400.0}
    assert c.catalog.max_semblances == 6
    assert c.catalog.symbols["form.semblance"].integer == ["shape"]
    assert c.catalog.symbols["act.dispel"].slots == %{}

    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(Map.delete(c.data, "semblance"))) end
    # 类别与实现不符（form.semblance 标成 act）同样拒绝。
    wrong = update_in(c.data, ["symbols"], fn symbols ->
      Enum.map(symbols, &if(&1["id"] == "form.semblance", do: %{&1 | "category" => "act"}, else: &1))
    end)
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(wrong)) end
  end

  test "UE 发布字节：DA_MagicCatalogV1 版本 2 冻结样本（%.17g 数值、integer 槽、取能 2 MJ 预设）原样加载、预设可施放" do
    # 冻结样本 = Voxim Content/Voxel/Magic/Published/fa4435e7….json 原字节（Voxim 20ad218，部署进服务端的就是这份）。
    digest = "fa4435e7952e2c6391e0827d179bfda068c003bbba14d71e8e0e2358c97d1ac4"
    bytes = File.read!(Path.expand("fixtures/magic/#{digest}.json", __DIR__))
    assert bytes =~ ~s("radius_m":0.40000000000000002) and bytes =~ ~s("integer":true)
    catalog = Catalog.decode(bytes)
    assert Base.encode16(catalog.digest, case: :lower) == digest
    assert catalog.semblance == %{specific_heat: 500.0, conductivity: 400.0}
    assert catalog.symbols["form.semblance"].integer == ["shape"]
    presets = Map.new(Jason.decode!(bytes)["presets"], &{&1["id"], &1["program"]})
    assert Enum.sort(Map.keys(presets)) == ~w(dispel draw_1mj draw_2mj hot_throw ignite_near light_orb)
    {:ok, throw} = Program.validate(presets["hot_throw"], catalog)
    # 手算：C = 2 kg × 500 = 1000 J/K，ΔT = 1706.85 K → 1 706 850 J；½·2·12² = 144 J；E_phys = 1 706 994 J；
    # E_loss = 14 256.08 J（前摇契约 §2 手算表，至 0.01 J）。
    q = Cost.quote(throw, catalog, 293.15)
    assert_in_delta q.physical_j, 1_706_994.0, 1.0e-6
    assert_in_delta q.loss_j, 14_256.08, 0.01
    {:ok, orb} = Program.validate(presets["light_orb"], catalog)
    # 光球：C·ΔT = 0，发光 100 W × 120 s = 12 000 J；E_loss = 1290.01 J（契约表）。
    q = Cost.quote(orb, catalog, 293.15)
    assert_in_delta q.physical_j, 12_000.0, 1.0e-6
    assert_in_delta q.loss_j, 1290.01, 0.01
    assert {:ok, %{steps: [%{sym: "energy.draw", args: %{"energy_j" => 2.0e6}}]}} = Program.validate(presets["draw_2mj"], catalog)
    assert {:ok, %{emit: :at_target}} = Program.validate(presets["dispel"], catalog)
  end

  test "程序形态：三个预设合法；形态与发出方式不符、形状非整数、只投不形一律 invalid_program", c do
    assert {:ok, %{emit: :hand, steps: [%{sym: "form.semblance"}, %{sym: "act.throw", args: %{"speed_mps" => 12.0}}]}} =
             Program.validate(preset(c, "hot_throw"), c.catalog)
    assert {:ok, %{emit: :hand, steps: [%{sym: "form.semblance"}]}} = Program.validate(preset(c, "light_orb"), c.catalog)
    assert {:ok, %{emit: :at_target, steps: [%{sym: "act.dispel", args: %{}}]}} = Program.validate(preset(c, "dispel"), c.catalog)

    invalid = [
      program("at_target", [form(ball()), toss(12)]),
      program("hand", [toss(12)]),
      program("hand", [toss(12), form(ball())]),
      program("hand", [form(ball()), toss(12), toss(12)]),
      program("hand", [form(%{ball() | "shape" => 0.5})]),
      program("hand", [form(%{ball() | "shape" => 2})]),
      program("hand", [form(Map.delete(ball(), "glow_w"))]),
      program("hand", [form(ball()), toss(31)]),
      program("hand", [%{"sym" => "act.dispel", "args" => %{}}]),
      program("at_target", [%{"sym" => "act.dispel", "args" => %{"id" => 1}}])
    ]

    for value <- invalid, do: assert({:error, :invalid_program} == Program.validate(value, c.catalog), inspect(value))
  end

  test "成本与前摇：炽热投掷、光球、驱散三行按契约手算表（环境 293.15 K，1e-6 相对）；形 + 投合并损耗大于拆开之和", c do
    {:ok, hot} = Program.validate(preset(c, "hot_throw"), c.catalog)
    # C = 2 kg × 500 J/(kg·K) = 1000 J/K；热内容 1000 × (2000 − 293.15) = 1 706 850 J；发光 0；动能 ½ × 2 × 12² = 144 J。
    # 〈形〉(90, 90, 90, 45)° 自静息：d₁ = √26325° = 2.831793 rad；S₁ = 1、H₁ = 1 706 850 → b₁ = 1000·2.70685^1.5 = 4453.447 W；
    #   T_adj = d₁·√(50/b₁) = 0.300053 s，T_inj = 1.70685 s，L₁ = 2·d₁·√(50·b₁) + b₁·1.70685 = 10 273.909 J。
    # 〈投〉(0, 0, −45, 90)° 自〈形〉：Δ = (−90, −90, −135, 45)°，d₂ = √36450° = 3.332162 rad；S₂ = 2、H₂ = 1 706 994 →
    #   b₂ = 1000·3.706994^1.5 = 7137.281 W；T_adj = 0.278898 s，T_inj = 0.000144 s，L₂ = 3982.169 J。
    # 前摇 = 2.285945 s；E_loss = 14 256.078 J；总支出 = 1 721 250.078 J。
    q = Cost.quote(hot, c.catalog, 293.15)
    assert q.structure == 2.0
    assert_in_delta q.physical_j, 1_706_994.0, 1.0e-6
    [{a1, i1}, {a2, i2}] = q.steps
    rel(a1, 0.30005330667)
    rel(i1, 1.70685)
    rel(a2, 0.27889756578)
    rel(i2, 0.000144)
    rel(q.windup_s, 2.2859448725)
    rel(q.loss_j, 14_256.077564)
    rel(q.total_j, 1_721_250.077564)

    # 超线性（§4.2）：“只形”一道 L = 10 273.909 J（与合并的第 1 步相同），“只投”不是可成立的程序（无拟态可投），
    # 手算自静息 d = 100.623° = 1.756204 rad、S = 1、H = 144 J → b = 1000.216 W、L = 785.627 J；拆开合计 11 059.536 J，
    # 小于合并的 14 256.078 J。
    [form_step, _] = hot.steps
    only_form = Cost.quote(%{steps: [form_step]}, c.catalog, 293.15)
    rel(only_form.loss_j, 10_273.908934)
    assert q.loss_j > only_form.loss_j + 785.627016

    {:ok, light} = Program.validate(preset(c, "light_orb"), c.catalog)
    # 光球：温度 = 环境，热内容 0；发光预算 100 W × 120 s = 12 000 J；〈形〉d = 2.831793 rad，S = 1、H = 12 000 →
    # b = 1000·1.012^1.5 = 1018.054 W；T_adj = 0.627569 s，T_inj = 0.012 s，前摇 0.639569 s；L = 1290.014 J。
    q = Cost.quote(light, c.catalog, 293.15)
    assert {q.structure, q.physical_j} == {1.0, 12_000.0}
    rel(q.windup_s, 0.63956855593)
    rel(q.loss_j, 1290.0138690)

    {:ok, dispel} = Program.validate(preset(c, "dispel"), c.catalog)
    # 驱散：〈散〉(−135, 135, −135, 135)°，d = 270° = 4.712389 rad；E = 0 → b = 1000 W；T_adj = 1.053722 s；L = 2107.444 J。
    q = Cost.quote(dispel, c.catalog, 293.15)
    assert {q.structure, q.physical_j} == {1.0, 0.0}
    assert [{_, +0.0}] = q.steps
    rel(q.windup_s, 1.0537222097)
    rel(q.loss_j, 2107.4444193)
    rel(q.total_j, 2107.4444193)
  end

  # 平地 y = 0 以下全是实占用：线段穿过 y = 0 时返回穿越点所在的 y = −1 层微格。
  defp ground(origin, {dx, dy, dz}, length, state) do
    {x, y, z} = origin

    if dy < 0 and y + dy * length < 0 do
      s = y / -dy
      {{:ground, {floor((x + dx * s) * 8), -1, floor((z + dz * s) * 8)}}, state + 1}
    else
      {nil, state + 1}
    end
  end

  test "弹道：手边 y = 2 m、vx = 10 m/s、地面 y = 0 → t = √(2·2/9.81) = 0.638551 s、x = 6.385509 m；拟态停在地面上方一个半径" do
    {{:hit, t, {x, y, z}, :ground}, _casts} =
      Semblance.trace({0.0, 2.0, 0.0}, {0.0, 2.0, 0.0}, {10.0, 0.0, 0.0}, 0.25, 30.0, 0, &ground/4)

    assert_in_delta t, 0.638551, 1.0e-6
    assert_in_delta x, 6.385509, 1.0e-6
    assert {y, z} == {0.25, +0.0}
    # 静止形态（速度 0）眼 → 手无遮挡：停在手边；眼 → 手之间就是地面：落在交点（t = 0）。
    assert {{:free, {+0.0, 1.0, 0.5}}, _} = Semblance.trace({0.0, 1.0, 0.0}, {0.0, 1.0, 0.5}, {0.0, 0.0, 0.0}, 0.1, 30.0, 0, &ground/4)
    assert {{:hit, +0.0, {_, 0.1, _}, :ground}, _} =
             Semblance.trace({0.0, 0.2, 0.0}, {0.0, -0.3, 0.0}, {0.0, 0.0, 0.0}, 0.1, 30.0, 0, &ground/4)
    # 竖直上抛 30 m/s：30 m 路程内不落地 → miss。
    assert {:miss, _} = Semblance.trace({0.0, 2.0, 0.0}, {0.0, 2.0, 0.0}, {0.0, 30.0, 0.0}, 0.25, 30.0, 0, &ground/4)
  end

  test "外部节点：拟态与一个叶宏格两节点无环境交换时能量守恒，趋热容加权平衡温度", c do
    # 拟态：球 r = 0.25 m、C = 1000 J/K、1293.15 K；叶：C = 1200 J/K、k = 50、293.15 K，宏格法向半程 0.5 m。
    # G = A / (r/k_s + d/k_o) = (π·0.25²) / (0.25/400 + 0.5/50) = 0.1963495 / 0.010625 = 18.479957 W/K。
    # 平衡温度 = (1000 × 1293.15 + 1200 × 293.15) / 2200 = 747.695455 K；等效热容 1000×1200/2200 = 545.45 J/K，
    # 时间常数 545.45 / 18.48 ≈ 29.5 s，600 s 后残差 ≈ 1000 K × e^−20.3 ≈ 1.5e−6 K。
    s = Semblance.new(1, %{"shape" => 0.0, "radius_m" => 0.25, "mass_kg" => 2.0, "temperature_k" => 1293.15,
      "glow_w" => 0.0, "lifetime_s" => 600.0}, c.catalog,
      %{origin: {0.0, 0.0, 0.0}, velocity: {0.0, 0.0, 0.0}, t0_us: 0, flight_s: 0.0, rest: {0.0, 0.0, 0.0}, contact: nil})
    area = :math.pi() * 0.25 * 0.25
    g = Semblance.conductance(s, c.catalog.semblance.conductivity, 50.0, 0.5, area)
    assert_in_delta g, 18.479957, 1.0e-6
    leaf = {293.15, 20.0, 20.0, 1200.0, 50.0, 1900.0, 0.0, 0.0, 0.0, true}
    nodes = [leaf, Semblance.node(s, c.catalog.semblance.conductivity, area)]

    {done, [{leaf_t, _, _}, {semblance_t, _, _}], supplied, environment} =
      VoxelRegion.ThermalNative.advance(nodes, [{0, 1, g}], 293.15, 0.0, 1.0, 600.0, {[], []})

    assert done == 600.0
    assert {supplied, environment} == {0.0, 0.0}
    assert_in_delta 1200 * (leaf_t - 293.15) + 1000 * (semblance_t - 1293.15), 0.0, 1.0e-6
    assert_in_delta leaf_t, 747.695455, 1.0e-4
    assert_in_delta semblance_t, 747.695455, 1.0e-4
  end

  # 接触几何（手算）：r = 0.4 m 球的包围立方体边长 0.8 m；完整落在一个宏格面上时面积 = 0.8² × π/4 = 0.5026548 m² = πr²。
  defp ball_at(rest, shape \\ 0),
    do: %{shape: shape, radius_m: 0.4, rest: rest}

  defp cell_box({x, y, z}), do: {{x * 1.0, y * 1.0, z * 1.0}, {x + 1.0, y + 1.0, z + 1.0}}

  test "接触几何：同一孤立叶格从侧面（−z 面）与从下方（−y 面）接触，面积同为 πr²、法向各为该面轴；分离即无接触" do
    leaf = cell_box({0, 2, 3})
    side = ball_at({0.5, 2.5, 2.6})
    below = ball_at({0.5, 1.6, 3.5})
    assert {area, 2} = Semblance.contact(side, leaf)
    assert_in_delta area, :math.pi() * 0.16, 1.0e-12
    assert {^area, 1} = Semblance.contact(below, leaf)
    # 候选宏格：侧面球立方体 x [0.1, 0.9]、y [2.1, 2.9]、z [2.2, 3.0] → 贴面的 z = 3 格在内。
    assert Semblance.span(side) == [{0, 2, 2}, {0, 2, 3}]
    # 离面 1 cm：不接触。
    assert Semblance.contact(ball_at({0.5, 2.5, 2.59}), leaf) == nil
    # 立方体形状整面：0.8² = 0.64 m²。
    assert {cube, 2} = Semblance.contact(ball_at({0.5, 2.5, 2.6}, 1), leaf)
    assert_in_delta cube, 0.64, 1.0e-12
  end

  test "接触几何：球心停在两叶格的分界上方 → 两条接触边各半面积；压进地面旁的墙格 → 地面与墙各一条（墙按最小重叠轴）" do
    # 球心 x = 1.0 正在 (0,2,3) 与 (1,2,3) 的分界：x 重叠各 0.4 → 各 0.4 × 0.8 × π/4 = 0.2513274 m²，合计 πr²。
    ball = ball_at({1.0, 2.5, 2.6})
    {a, 2} = Semblance.contact(ball, cell_box({0, 2, 3}))
    {b, 2} = Semblance.contact(ball, cell_box({1, 2, 3}))
    assert_in_delta a, 0.32 * :math.pi() / 4, 1.0e-12
    assert_in_delta a + b, :math.pi() * 0.16, 1.0e-12
    # 落在 y = 1 地面顶面上、球心 x = 0.85：立方体 x [0.45, 1.25] 压进 (1,1,0) 墙格 0.25 m（最小重叠轴 x），
    # 墙面积 = y 重叠 [1.0, 1.8] 0.8 × z 重叠 0.8 × π/4 = πr²；地面 (0,0,0) 只接 x [0.45, 1.0] 部分：0.55 × 0.8 × π/4。
    floor_ball = ball_at({0.85, 1.4, 0.5})
    assert {wall, 0} = Semblance.contact(floor_ball, cell_box({1, 1, 0}))
    assert_in_delta wall, :math.pi() * 0.16, 1.0e-12
    assert {ground, 1} = Semblance.contact(floor_ball, cell_box({0, 0, 0}))
    assert_in_delta ground, 0.55 * 0.8 * :math.pi() / 4, 1.0e-12
  end

  test "外部节点：一个拟态与两个格按两条接触边、无环境交换时能量守恒，三节点趋热容加权平衡温度", c do
    # 拟态 C = 1000 J/K、1293.15 K；两格 C = 1200 / 21360 J/K、k = 50 / 25、293.15 K，面积按分界球各半 0.2513274 m²。
    # 平衡温度 = (1000 × 1293.15 + (1200 + 21360) × 293.15) / 23560 = 335.594652 K。
    s = Semblance.new(1, %{"shape" => 0.0, "radius_m" => 0.4, "mass_kg" => 2.0, "temperature_k" => 1293.15,
      "glow_w" => 0.0, "lifetime_s" => 6000.0}, c.catalog,
      %{origin: {1.0, 2.5, 2.6}, velocity: {0.0, 0.0, 0.0}, t0_us: 0, flight_s: 0.0, rest: {1.0, 2.5, 2.6}, contact: nil})
    half = 0.32 * :math.pi() / 4
    k = c.catalog.semblance.conductivity
    leaf = {293.15, 20.0, 20.0, 1200.0, 50.0, 1900.0, 0.0, 0.0, 0.0, true}
    stone = {293.15, 20.0, 20.0, 21_360.0, 25.0, 1900.0, 0.0, 0.0, 0.0, true}
    edges = [{0, 2, Semblance.conductance(s, k, 50.0, 0.5, half)}, {1, 2, Semblance.conductance(s, k, 25.0, 0.5, half)}]
    {6000.0, [{leaf_t, _, _}, {stone_t, _, _}, {ball_t, _, _}], +0.0, +0.0} =
      VoxelRegion.ThermalNative.advance([leaf, stone, Semblance.node(s, k, 2 * half)], edges, 293.15, 0.0, 1.0e-3, 6000.0, {[], []})
    assert_in_delta 1200 * (leaf_t - 293.15) + 21_360 * (stone_t - 293.15) + 1000 * (ball_t - 1293.15), 0.0, 1.0e-3
    for t <- [leaf_t, stone_t, ball_t], do: assert_in_delta(t, 335.594652, 0.01)
  end

  test "一段演进：流出 = C·ΔT；发光按余寿计光；落地时飞行动能转为内能；寿命端点对齐", c do
    s = Semblance.new(1, %{"shape" => 0.0, "radius_m" => 0.1, "mass_kg" => 1.0, "temperature_k" => 400.0,
      "glow_w" => 10.0, "lifetime_s" => 1.0}, c.catalog,
      %{origin: {0.0, 0.0, 0.0}, velocity: {0.0, 0.0, 10.0}, t0_us: 0, flight_s: 0.3, rest: {0.0, 0.0, 3.0}, contact: nil})
    # C = 500 J/K；动能 ½ × 1 × 10² = 50 J；剩余 = 500 × (400 − 293.15) + 50 + 10 × 1 = 53 485 J。
    assert_in_delta Semblance.stored_j(s, 293.15), 53_485.0, 1.0e-9
    assert Semblance.cap([s], 0.5) == 0.3
    {s, light, out} = Semblance.step(s, 390.0, 0.3)
    # 流出 500 × 10 = 5000 J；光 10 W × 0.3 s = 3 J；落地 ΔT = 50 / 500 = 0.1 K。
    assert_in_delta light, 3.0, 1.0e-12
    assert_in_delta out, 5000.0, 1.0e-9
    assert_in_delta s.temperature_k, 390.1, 1.0e-12
    assert s.kinetic_j == 0.0 and Semblance.landed?(s)
    assert_in_delta Semblance.cap([s], 1.0), 0.7, 1.0e-12
    {s, light, _} = Semblance.step(s, 390.1, 0.7)
    assert_in_delta light, 7.0, 1.0e-12
    assert Semblance.expired?(s)
  end

  test "窗口投影：出发点或落点在窗口内的拟态保留，删除总保留" do
    inside = %{origin: {1.0, 1.0, 1.0}, rest: {2.0, 1.0, 1.0}}
    outside = %{origin: {500.0, 1.0, 1.0}, rest: {501.0, 1.0, 1.0}}
    value = %{semblances: %{{1, 0} => inside, {2, 0} => outside, {3, 0} => nil}}
    projected = VoxelRegion.PropertyObservation.project(value, {{0, 0, 0}, {1, 1, 1}})
    assert projected.semblances == %{{1, 0} => inside, {3, 0} => nil}
  end
end
