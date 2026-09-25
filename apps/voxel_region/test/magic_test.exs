defmodule VoxelRegion.MagicTest do
  @moduledoc """
  只测试：魔法纯模块（目录、程序、成本与前摇）。夹具 `fixtures/magic/ff15757b….json` 是按契约 JSON 结构手写的
  Test-only 目录（增量 1 内容，目录版本 2：符号姿态、构型损耗参数与最大输出功率，数值同前摇契约首片），不是 UE 发布物；
  期望值全部按契约公式手算（前摇契约 §2 手算表，写在各断言旁），不取自被测函数。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.{Catalog, Cost, Program}

  @digest "ff15757b8a7bfc20954ffde9370f04f0bc22b8a0b93fe31e03eb893165c7e9b1"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)
  # UE 发布字节：Voxim Content/Voxel/Magic/Published/fa4435e7….json（DA_MagicCatalogV1 版本 2，Voxim 20ad218）。
  @ue "fa4435e7952e2c6391e0827d179bfda068c003bbba14d71e8e0e2358c97d1ac4"

  setup_all do
    %{catalog: Catalog.load(@path), data: Jason.decode!(File.read!(@path))}
  end

  defp program(steps), do: %{"v" => 1, "target" => %{"kind" => "aim"}, "emit" => "at_target", "steps" => steps}
  defp heat(energy, power), do: %{"sym" => "act.heat", "args" => %{"energy_j" => energy, "power_w" => power}}
  defp draw(energy), do: %{"sym" => "energy.draw", "args" => %{"energy_j" => energy}}
  defp parse(c, value), do: Program.parse(Jason.encode!(value), c.catalog)
  defp rel(actual, expected), do: assert(abs(actual - expected) <= 1.0e-6 * abs(expected), "#{actual} vs #{expected}")

  defp symbol(data, id, fun),
    do: update_in(data, ["symbols"], fn symbols -> Enum.map(symbols, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)

  test "目录：digest = 文件字节 sha256；版本 2 数值与姿态（度 → 弧度）；未实现动词、缺字段、旧版本与非法姿态不能加载", c do
    assert Base.encode16(c.catalog.digest, case: :lower) == @digest
    assert {c.catalog.capacity_j, c.catalog.coherence, c.catalog.draw_efficiency} == {5.0e6, 4.0, 0.9}
    assert {c.catalog.range_m, c.catalog.local_domain_m, c.catalog.cast_interval_us} == {30.0, 6.0, 500_000}
    assert {c.catalog.eta, c.catalog.b0_w, c.catalog.max_power_w} == {50.0, 1000.0, 1.0e6}
    assert {c.catalog.e_ref_j, c.catalog.alpha} == {1.0e6, 1.5}
    refute Map.has_key?(c.catalog, :e0_j)
    assert c.catalog.symbols["act.heat"].slots == %{"energy_j" => {1000, 4_000_000}, "power_w" => {1000, 200_000}}
    # 〈热〉(+45, −90, +90, −90)° = (π/4, −π/2, π/2, −π/2)。
    for {a, e} <- Enum.zip(c.catalog.symbols["act.heat"].pose, [:math.pi() / 4, -:math.pi() / 2, :math.pi() / 2, -:math.pi() / 2]),
        do: assert_in_delta(a, e, 1.0e-12)

    unknown = update_in(c.data, ["symbols"], &[%{hd(&1) | "id" => "act.cool"} | tl(&1)])
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(unknown)) end
    missing = update_in(c.data, ["limits"], &Map.delete(&1, "cast_interval_ms"))
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(missing)) end
    # 预设必须是可施放程序：步数 2 的预设整份拒绝。
    bad = update_in(c.data, ["presets"], fn [p | rest] -> [put_in(p, ["program", "steps"], [draw(1000), draw(1000)]) | rest] end)
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(bad)) end

    # 版本 1、缺最大输出功率、缺 η、只有旧控制开销参数的目录拒绝。
    rejected = [
      %{c.data | "version" => 1},
      update_in(c.data, ["caster"], &Map.delete(&1, "max_power_w")),
      update_in(c.data, ["cost"], &Map.delete(&1, "eta_j_s_per_rad2")),
      Map.put(c.data, "cost", %{"e0_j" => 2000, "e_ref_j" => 1_000_000, "alpha" => 1.5}),
      # 姿态：缺失、3 个关节、非 45 的倍数、超出 ±135、非整数。
      symbol(c.data, "act.heat", &Map.delete(&1, "pose")),
      symbol(c.data, "act.heat", &%{&1 | "pose" => [45, -90, 90]}),
      symbol(c.data, "act.heat", &%{&1 | "pose" => [30, -90, 90, -90]}),
      symbol(c.data, "act.heat", &%{&1 | "pose" => [180, -90, 90, -90]}),
      symbol(c.data, "act.heat", &%{&1 | "pose" => [45.0, -90, 90, -90]})
    ]

    for data <- rejected, do: assert_raise(MatchError, fn -> Catalog.decode(Jason.encode!(data)) end)
  end

  test "UE 发布字节：DA_MagicCatalogV1 版本 2 的冻结样本（%.17g 数值：整数 4、0.90000000000000002）原样加载" do
    # 冻结样本 = UE 发布文件原字节（部署进服务端的就是这份）。
    bytes = File.read!(Path.expand("fixtures/magic/#{@ue}.json", __DIR__))
    assert bytes =~ ~s("coherence":4,) and bytes =~ ~s("draw_efficiency":0.90000000000000002)
    catalog = Catalog.decode(bytes)
    assert Base.encode16(catalog.digest, case: :lower) == @ue
    assert {catalog.capacity_j, catalog.coherence, catalog.draw_efficiency, catalog.max_power_w} == {5.0e6, 4.0, 0.9, 1.0e6}
    assert {catalog.local_domain_m, catalog.cast_interval_us, catalog.program_max_bytes} == {6.0, 500_000, 2048}
    assert {catalog.eta, catalog.b0_w, catalog.e_ref_j, catalog.alpha} == {50.0, 1000.0, 1.0e6, 1.5}
    # 姿态同前摇契约 §3：〈散〉(−135, 135, −135, 135)°。
    for {a, e} <- Enum.zip(catalog.symbols["act.dispel"].pose, [-0.75, 0.75, -0.75, 0.75]),
        do: assert_in_delta(a, e * :math.pi(), 1.0e-12)
    # 远程点火预设 0.4 MJ / 200 kW 可施放。
    ignite = Jason.decode!(bytes)["presets"] |> Enum.find(&(&1["id"] == "ignite_near"))
    assert {:ok, %{steps: [%{args: %{"energy_j" => 4.0e5, "power_w" => 2.0e5}}]}} = Program.validate(ignite["program"], catalog)
  end

  test "程序：两个预设合法；非法各类一律 :invalid_program", c do
    assert {:ok, %{steps: [%{sym: "energy.draw", args: %{"energy_j" => 1.0e6}}]}} = parse(c, program([draw(1_000_000)]))
    assert {:ok, %{steps: [%{sym: "act.heat", args: %{"energy_j" => 4.0e5, "power_w" => 5.0e4}}]}} =
             parse(c, program([heat(400_000, 50_000)]))

    invalid = [
      # 未知符号
      program([%{"sym" => "act.cool", "args" => %{"energy_j" => 1000}}]),
      # 槽缺失 / 多余槽
      program([%{"sym" => "act.heat", "args" => %{"energy_j" => 400_000}}]),
      program([%{"sym" => "energy.draw", "args" => %{"energy_j" => 1000, "power_w" => 1000}}]),
      # 越界：下界 1000 J、上界 4 MJ、功率上界 200 kW；非数
      program([heat(999, 50_000)]),
      program([heat(4_000_001, 50_000)]),
      program([heat(400_000, 200_001)]),
      program([heat("400000", 50_000)]),
      # 步数：0、增量 1 只接受 1 步（2 步）、超过 max_steps 8（9 步）
      program([]),
      program([draw(1000), draw(1000)]),
      program(List.duplicate(draw(1000), 9)),
      # 目标、发出、版本只接受增量 1 形态；多余键
      %{program([draw(1000)]) | "target" => %{"kind" => "self"}},
      %{program([draw(1000)]) | "emit" => "hand"},
      %{program([draw(1000)]) | "v" => 2},
      Map.put(program([draw(1000)]), "extra", 1)
    ]

    for value <- invalid, do: assert({:error, :invalid_program} == parse(c, value), inspect(value))
    assert {:error, :invalid_program} == Program.parse("{not json", c.catalog)
    # 字节上限 2048：合法结构后补空白到 2049 字节。
    bytes = Jason.encode!(program([draw(1000)]))
    assert {:ok, _} = Program.parse(bytes <> String.duplicate(" ", 2048 - byte_size(bytes)), c.catalog)
    assert {:error, :invalid_program} == Program.parse(bytes <> String.duplicate(" ", 2049 - byte_size(bytes)), c.catalog)
  end

  test "成本与前摇：取能、远程点火两行按契约手算表（1e-6 相对）；同符号相邻两步 d = 0 只剩维护与注能", c do
    {:ok, d} = parse(c, program([draw(1_000_000)]))
    # 取能：姿态 (−90, −90, −45, 0)°，d = √(90² + 90² + 45²)° = 135° = 2.356194 rad；E = 0，S = 1 → b = 1000 W；
    # T_adj = d·√(50/1000) = 0.526861 s，T_inj = 0；L = 2·d·√(50·1000) = 1053.722 J。总支出 = 1053.722 J。
    q = Cost.quote(d, c.catalog)
    assert {q.structure, q.physical_j} == {1.0, 0.0}
    [{adjust, inject}] = q.steps
    rel(adjust, 0.52686110483)
    assert inject == 0.0
    rel(q.windup_s, 0.52686110483)
    rel(q.loss_j, 1053.7222097)
    rel(q.total_j, 1053.7222097)

    {:ok, h} = parse(c, program([heat(400_000, 50_000)]))
    # 远程点火：〈热〉(45, −90, 90, −90)°，d = √26325° = 162.2498° = 2.831793 rad；E = 0.4 MJ，S = 1 →
    # b = 1000·(1 + 0.4)^1.5 = 1656.502 W；T_adj = d·√(50/b) = 0.491983 s；T_inj = 0.4 MJ / 1 MW = 0.4 s；前摇 0.891983 s；
    # L = 2·d·√(50·b) + b·0.4 = 1629.944 + 662.601 = 2292.545 J；总支出 = 402 292.545 J。
    q = Cost.quote(h, c.catalog)
    assert {q.structure, q.physical_j} == {1.0, 4.0e5}
    [{adjust, inject}] = q.steps
    rel(adjust, 0.49198349452)
    rel(inject, 0.4)
    rel(q.windup_s, 0.89198349452)
    rel(q.loss_j, 2292.5445548)
    rel(q.total_j, 402_292.5445548)

    # 两步同符号（纯公式；执行器不接受此形态）：第 2 步 d = 0，T_adj = 0；S = 2、H = 0.8 MJ → b = 1000·2.8^1.5 = 4685.296 W，
    # L_2 = b·0.4 = 1874.118 J；合计 E_loss = 2292.545 + 1874.118 = 4166.663 J，前摇 0.891983 + 0.4 = 1.291983 s。
    # 注意：它小于拆成两道之和 4585.089 J——同符号重复时合并反而便宜（见前摇契约 §2 与设计 §13.6 的待定形态）。
    merged = Cost.quote(%{steps: h.steps ++ h.steps}, c.catalog)
    assert [_, {+0.0, inject2}] = merged.steps
    rel(inject2, 0.4)
    rel(merged.loss_j, 4166.6630142)
    rel(merged.windup_s, 1.2919834945)

    # 超线性（§4.2，不同符号）：取能 → 点火合并：第 1 步同上 1053.722 J；第 2 步自〈取〉到〈热〉Δ = (135, 0, 135, −90)°，
    # d = √44550° = 211.0687° = 3.683844 rad，S = 2、H = 0.4 MJ → b = 1000·2.4^1.5 = 3718.064 W，
    # L₂ = 2·d·√(50·b) + b·0.4 = 4663.914 J；合并 5717.636 J，大于拆开之和 1053.722 + 2292.545 = 3346.267 J。
    chained = Cost.quote(%{steps: d.steps ++ h.steps}, c.catalog)
    rel(chained.loss_j, 5717.6364614)
    rel(chained.windup_s, 1.3540577099)
    assert chained.loss_j > Cost.quote(d, c.catalog).loss_j + Cost.quote(h, c.catalog).loss_j
  end

  test "走火判定：相干度先于能量；取能分账", c do
    quote = %{structure: 1.0, total_j: 302_964.4}
    assert Cost.misfire(quote, 302_964.4, c.catalog) == nil
    assert Cost.misfire(quote, 100_000.0, c.catalog) == :misfire_energy
    # S = 5 > 相干度 4：即使能量足够也走火，且先报相干度。
    assert Cost.misfire(%{quote | structure: 5.0}, 1.0e9, c.catalog) == :misfire_coherence
    assert Cost.misfire(%{quote | structure: 5.0}, 0.0, c.catalog) == :misfire_coherence
    assert Cost.misfire(%{quote | structure: 4.0}, 1.0e9, c.catalog) == nil

    # 10 MJ 石取 1 MJ，η 0.9，余额 0：ΔE = min(1 MJ, 10 MJ, 5 MJ − 0) = 1 MJ → 得 0.9 MJ、损耗 0.1 MJ。
    d = Cost.draw(1.0e6, 1.0e7, 0.0, c.catalog)
    assert d.taken_j == 1.0e6
    assert_in_delta d.gained_j, 9.0e5, 1.0e-6
    assert_in_delta d.loss_j, 1.0e5, 1.0e-6
    # 石只剩 0.3 MJ → ΔE = 0.3 MJ；余额 4.9 MJ → 容量余量 0.1 MJ 封顶。
    assert Cost.draw(1.0e6, 3.0e5, 0.0, c.catalog).taken_j == 3.0e5
    assert_in_delta Cost.draw(1.0e6, 1.0e7, 4.9e6, c.catalog).taken_j, 1.0e5, 1.0e-6
  end
end
