defmodule VoxelRegion.MagicSemblanceTest do
  @moduledoc """
  只测试：魔法增量 2 纯规则（目录、程序形态、拟态成本、运动学弹道、拟态作为热内核外部节点）。
  夹具 `fixtures/magic/0e8ecf14….json` 是按契约 JSON 结构手写的 Test-only 目录（增量 1 内容 + `semblance` 段、
  `form.semblance` / `act.throw` / `act.dispel` 与三个预设），不是 UE 发布物；期望值全部手算，写在断言旁。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Semblance}

  @digest "0e8ecf1497829de1a91a65256377c335c447035e8693756c894e7f803d820d3a"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)

  setup_all do
    %{catalog: Catalog.load(@path), data: Jason.decode!(File.read!(@path))}
  end

  defp preset(c, id), do: Enum.find(c.data["presets"], &(&1["id"] == id))["program"]
  defp form(args), do: %{"sym" => "form.semblance", "args" => args}
  defp toss(v), do: %{"sym" => "act.throw", "args" => %{"speed_mps" => v}}
  defp program(emit, steps), do: %{"v" => 1, "target" => %{"kind" => "aim"}, "emit" => emit, "steps" => steps}
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

  test "成本：炽热投掷、光球、驱散三例手算（环境 293.15 K）", c do
    {:ok, hot} = Program.validate(preset(c, "hot_throw"), c.catalog)
    # C = 2 kg × 500 J/(kg·K) = 1000 J/K；热内容 1000 × (2000 − 293.15) = 1 706 850 J；发光 0；动能 ½ × 2 × 12² = 144 J。
    # E_phys = 1 706 994 J；S = 2；E_ctl = 2000 × (2 + 1.706994)^1.5 = 2000 × 3.706994 × √3.706994
    #        = 2000 × 3.706994 × 1.9253556 = 2000 × 7.1372815 = 14 274.563 J。
    q = Cost.quote(hot, c.catalog, 293.15)
    assert q.structure == 2.0
    assert_in_delta q.physical_j, 1_706_994.0, 1.0e-6
    assert_in_delta q.control_j, 14_274.563, 1.0e-3
    assert_in_delta q.total_j, 1_721_268.563, 1.0e-3

    {:ok, light} = Program.validate(preset(c, "light_orb"), c.catalog)
    # 温度 = 环境：热内容 0；发光预算 100 W × 120 s = 12 000 J；E_ctl = 2000 × 1.012^1.5 = 2000 × 1.012 × 1.0059821 = 2036.108 J。
    q = Cost.quote(light, c.catalog, 293.15)
    assert {q.structure, q.physical_j} == {1.0, 12_000.0}
    assert_in_delta q.control_j, 2036.108, 1.0e-3

    {:ok, dispel} = Program.validate(preset(c, "dispel"), c.catalog)
    # 驱散不注入物理能量：E_ctl = 2000 × 1^1.5 = 2000 J。
    assert Cost.quote(dispel, c.catalog, 293.15) == %{structure: 1.0, physical_j: 0.0, control_j: 2000.0, total_j: 2000.0}
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
    g = Semblance.conductance(s, c.catalog.semblance.conductivity, 50.0, 0.5)
    assert_in_delta g, 18.479957, 1.0e-6
    leaf = {293.15, 20.0, 20.0, 1200.0, 50.0, 1900.0, 0.0, 0.0, 0.0, true}
    nodes = [leaf, Semblance.node(s, c.catalog.semblance.conductivity, true)]

    {done, [{leaf_t, _, _}, {semblance_t, _, _}], supplied, environment} =
      VoxelRegion.ThermalNative.advance(nodes, [{0, 1, g}], 293.15, 0.0, 1.0, 600.0, {[], []})

    assert done == 600.0
    assert {supplied, environment} == {0.0, 0.0}
    assert_in_delta 1200 * (leaf_t - 293.15) + 1000 * (semblance_t - 1293.15), 0.0, 1.0e-6
    assert_in_delta leaf_t, 747.695455, 1.0e-4
    assert_in_delta semblance_t, 747.695455, 1.0e-4
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
