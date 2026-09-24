defmodule VoxelRegion.MagicTest do
  @moduledoc """
  只测试：魔法增量 1 纯模块（目录、程序、成本）。夹具 `fixtures/magic/8f418a41….json` 是按契约 JSON 结构手写的
  Test-only 目录（数值同契约初版），不是 UE 发布物；期望值全部按契约公式手算，写在各断言旁。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.{Catalog, Cost, Program}

  @digest "8f418a4136db1571d26ae6f54ac02268c45218e0738b74af671206876888f136"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)

  setup_all do
    %{catalog: Catalog.load(@path), data: Jason.decode!(File.read!(@path))}
  end

  defp program(steps), do: %{"v" => 1, "target" => %{"kind" => "aim"}, "emit" => "at_target", "steps" => steps}
  defp heat(energy, power), do: %{"sym" => "act.heat", "args" => %{"energy_j" => energy, "power_w" => power}}
  defp draw(energy), do: %{"sym" => "energy.draw", "args" => %{"energy_j" => energy}}
  defp parse(c, value), do: Program.parse(Jason.encode!(value), c.catalog)

  test "目录：digest = 文件字节 sha256；契约初版数值；未实现动词与缺字段的目录不能加载", c do
    assert Base.encode16(c.catalog.digest, case: :lower) == @digest
    assert {c.catalog.capacity_j, c.catalog.coherence, c.catalog.draw_efficiency} == {5.0e6, 4.0, 0.9}
    assert {c.catalog.range_m, c.catalog.local_domain_m, c.catalog.cast_interval_us} == {30.0, 6.0, 500_000}
    assert {c.catalog.e0_j, c.catalog.e_ref_j, c.catalog.alpha} == {2000.0, 1.0e6, 1.5}
    assert c.catalog.symbols["act.heat"].slots == %{"energy_j" => {1000, 4_000_000}, "power_w" => {1000, 200_000}}

    unknown = update_in(c.data, ["symbols"], &[%{hd(&1) | "id" => "act.cool"} | tl(&1)])
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(unknown)) end
    missing = update_in(c.data, ["limits"], &Map.delete(&1, "cast_interval_ms"))
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(missing)) end
    # 预设必须是可施放程序：步数 2 的预设整份拒绝。
    bad = update_in(c.data, ["presets"], fn [p | rest] -> [put_in(p, ["program", "steps"], [draw(1000), draw(1000)]) | rest] end)
    assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(bad)) end
  end

  test "UE 发布字节：DA_MagicCatalogV1 的冻结样本（%.17g 数值：整数 4、0.90000000000000002）原样加载" do
    # 冻结样本 = Voxim Content/Voxel/Magic/Published/2aaa8597….json 原字节（部署进服务端的就是这份）。
    digest = "2aaa859715037d66be72a833bbe142f9e0b8ea63866e91e076c80cca9cbee9f0"
    bytes = File.read!(Path.expand("fixtures/magic/#{digest}.json", __DIR__))
    assert bytes =~ ~s("coherence":4,) and bytes =~ ~s("draw_efficiency":0.90000000000000002)
    catalog = Catalog.decode(bytes)
    assert Base.encode16(catalog.digest, case: :lower) == digest
    assert {catalog.capacity_j, catalog.coherence, catalog.draw_efficiency} == {5.0e6, 4.0, 0.9}
    assert {catalog.local_domain_m, catalog.cast_interval_us, catalog.program_max_bytes} == {6.0, 500_000, 2048}
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

  test "成本：取能与远程点火两例手算；两步合并开销大于分开之和（超线性）", c do
    {:ok, d} = parse(c, program([draw(1_000_000)]))
    # 取能：S = 1，E_phys = 0；E_ctl = 2000 × (1 + 0)^1.5 = 2000 J；总支出 = 2000 J。
    assert Cost.quote(d, c.catalog) == %{structure: 1.0, physical_j: 0.0, control_j: 2000.0, total_j: 2000.0}

    {:ok, h} = parse(c, program([heat(400_000, 50_000)]))
    # 点火：S = 1，E_phys = 0.4 MJ；E_ctl = 2000 × 1.4^1.5 = 2000 × 1.4 × √1.4 = 2000 × 1.6565023 = 3313.0047 J；
    # 总支出 = 403 313.0047 J。
    q = Cost.quote(h, c.catalog)
    assert {q.structure, q.physical_j} == {1.0, 4.0e5}
    assert_in_delta q.control_j, 3313.0047, 1.0e-4
    assert_in_delta q.total_j, 403_313.0047, 1.0e-4

    # 超线性：两步各 0.4 MJ 合并 → S = 2，E_ctl = 2000 × 2.8^1.5 = 2000 × 2.8 × √2.8 = 2000 × 4.6852961 = 9370.5923 J；
    # 拆成两道各 3313.0047 J，合计 6626.0094 J < 9370.5923 J。
    merged = Cost.quote(%{steps: h.steps ++ h.steps}, c.catalog)
    assert_in_delta merged.control_j, 9370.5923, 1.0e-4
    assert merged.control_j > 2 * q.control_j
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
