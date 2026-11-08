defmodule VoxelRegion.PhaseSettlementTest do
  @moduledoc "只测试：相变结算的有限供能、广延量守恒和材料身份边界。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Phase

  defp materials do
    Map.new([{20, 21, 10.0, 80.0}, {21, 20, 20.0, 40.0}], fn {id, peer, heat, hp} ->
      {id,
       %{
         "phase_peer_material_id" => peer,
         "phase_transition_kelvin" => 273.0,
         "latent_heat_per_macro_j" => 100.0,
         "heat_capacity_per_macro" => heat,
         "max_hp_per_macro" => hp
       }}
    end)
    |> Map.put(0, %{})
  end

  test "舀取和混合库存倒回守恒焓和损伤，不用环境温度重置库存" do
    # 格值为整数（120 J = 120 000 000 µJ，60 单位完整度 ×1024 = 61 440），库存仍是浮点 {J, 数量单位}。
    cell = {120_000_000, 61_440}
    inventory = {-20.0, 10.0}
    {next_cell, next_inventory} = Phase.transfer(cell, inventory, 100, 25, :scoop)
    # 舀 25/100：120 J → 30 J、61 440 → 15 360 整除；库存 −20 + 30 = 10 J、10 + 15 = 25 单位。
    assert next_cell === {90_000_000, 46_080}
    assert next_inventory == {10.0, 25.0}
    # 库存混合后倒回全部，原格加原库存的焓/完整度仍守恒：90 + 10 = 100 J、45 + 25 = 70 单位 = 71 680。
    {final_cell, empty} = Phase.transfer(next_cell, next_inventory, 50, 50, :pour)
    assert final_cell === {100_000_000, 71_680}
    assert empty == {0.0, 0.0}
  end

  test "工具加热精确抵达潜热终点，多付能量只进未用账，冷却同样守恒" do
    heat = %{"action" => "phase.heat", "heat_energy_j" => 100.0}
    hot = Phase.tool_energy(-13.1, 0.25, materials()[20], heat)
    assert hot.energy == 25.0
    assert_in_delta hot.supplied_j, 38.1, 1.0e-12
    assert_in_delta hot.paid_j, hot.supplied_j + hot.unused_j, 1.0e-12
    assert Phase.material(20, hot.energy, 0.25, materials()) == 21

    cool =
      Phase.tool_energy(hot.energy, 0.25, materials()[21], %{
        "action" => "phase.cool",
        "cooling_energy_j" => 10.0
      })

    assert cool == %{energy: 15.0, supplied_j: -10.0, paid_j: 10.0, unused_j: 0.0}
    assert Phase.material(21, cool.energy, 0.25, materials()) == 21
  end

  test "部分格重新凝固按携带完整度恢复 HP，不修复损伤或改变身份字段" do
    row = %{material: 20, hp: 80.0, max_hp: 80.0, incarnation: 7, seq: 9}
    # −5 J = −5 000 000 µJ，10 单位完整度 ×1024 = 10 240；HP = 80 × 25/100 × 10/25 = 8，温度 273 + (−5)/(10 × 0.25) = 271。
    restored = Phase.restore(row, {-5_000_000, 10_240}, 25, 100, materials())
    assert restored.max_hp == 20.0
    assert restored.hp == 8.0
    assert restored.phase_energy_j == -5.0
    assert restored.temperature_kelvin == 271.0
    assert restored.incarnation == 7 and restored.seq == 9
  end

  test "只给新作者格初始化环境焓，运输值优先，清空不求零体积温度" do
    context = %{materials: materials(), capacity: 100, ambient: 283.0, material: 21}

    current = %{
      authored: {0, {0, 0}},
      moved: {0, {0, 0}},
      frozen: {21, {0, 10_240}},
      empty: {21, {3_000_000, 2048}}
    }

    {edits, values} =
      Phase.settle(
        %{authored: 25, moved: 25, frozen: 25, empty: 0},
        current,
        %{moved: {12_000_000, 8192}},
        context
      )

    assert Map.new(edits) == %{authored: 21, moved: 21, frozen: 20, empty: 0}
    # 新作者液格 0.25 m³ 在 283 K：0.25 × (潜热 100 + 20 × (283 − 273)) = 75 J；完整度 25 × 1024 = 25 600。
    assert values.authored === {75_000_000, 25_600}
    assert values.moved === {12_000_000, 8192}
    assert values.frozen === {0, 10_240}
  end

  test "净数量不变的中间格仍提交两阶段搬运的焓与完整度" do
    # 整数格值（µJ、完整度 ×1024）。阶段一 a→b 25/100：25 J、25 600；阶段二 b 冻结为 {25 J, 76 800}、q=125，
    # b→c 25/125：5 J、15 360。结果 a {75 J, 76 800}、b {20 J, 61 440}、c {5 J, 15 360}，全部整除。
    values = %{a: {100_000_000, 102_400}, b: {0, 51_200}}
    water = %{a: 100, b: 100}
    stages = [{water, [{:a, :b, 25}]}, {%{a: 75, b: 125}, [{:b, :c, 25}]}]
    {changes, transported} = Phase.transport_stages(values, water, %{a: 75, c: 25}, stages)
    assert changes == %{a: 75, b: 100, c: 25}
    assert transported === %{a: {75_000_000, 76_800}, b: {20_000_000, 61_440}, c: {5_000_000, 15_360}}
    assert Enum.sum(for {_, {e, _}} <- transported, do: e) === 100_000_000
    assert Enum.sum(for {_, {_, i}} <- transported, do: i) === 153_600
  end

  # 整数定点格值的回归（期望均为手算整数，见 Phase 的单位说明）。整数值用 ===：== 会把 1 与 1.0 判等。

  @burn_materials %{30 => %{"ignition_kelvin" => 560.0, "fuel_energy_per_macro_j" => 1.5e7,
    "burn_power_per_macro_w" => 2.0e4, "max_hp_per_macro" => 50.0, "heat_capacity_per_macro" => 1.0e4}}

  test "同一目标同阶段收三笔流，结果与流次序无关且精确等于各笔之和" do
    # 来源能量 1e16 J、1 J、−1e16 J（µJ 下 1e22、1e6、−1e22），各 1 单位全部流光到 c。
    # 精确和 = 1e22 + 1e6 − 1e22 = 1e6 µJ；浮点下 1e22 + 1e6 被吸收（ulp(1e22) ≈ 2e6），次序不同结果不同。
    big = 10_000_000_000_000_000_000_000
    values = %{a: {big, 1024, 0, false}, b: {1_000_000, 1024, 0, false}, d: {-big, 1024, 0, false}, c: {0, 0, 0, nil}}
    quantities = %{a: 1, b: 1, d: 1}
    flows = [{:a, :c, 1}, {:b, :c, 1}, {:d, :c, 1}]
    forward = Phase.transport(values, quantities, flows)
    assert forward === Phase.transport(values, quantities, Enum.reverse(flows))
    assert forward === Phase.transport(values, quantities, [{:b, :c, 1}, {:a, :c, 1}, {:d, :c, 1}])
    assert forward.c === {1_000_000, 3072, 0, false}
    assert forward.a === {0, 0, 0, false} and forward.b === {0, 0, 0, false} and forward.d === {0, 0, 0, false}
  end

  test "三分整除：源格各拆 1/3 给两格，各得下取整，余数留在源，总量逐整数守恒" do
    # 100 000 µJ、3 单位，两笔各 1 单位：floor(100 000 / 3) = 33 333，源留 100 000 − 2 × 33 333 = 33 334。
    # 累计取整（目标键序 x、y）：c_1 = 100 000/3 → 33 333，c_2 = 200 000/3 → 66 666，x 得 33 333、y 得 33 333，源留 33 334。
    # 完整度 3072：c_1 = 1024、c_2 = 2048 → 各 1024，源留 1024；已烧 7：c_1 = 7/3 → 2、c_2 = 14/3 → 4 → 各 2，源留 3。
    values = %{s: {100_000, 3072, 7, false}}
    next = Phase.transport(values, %{s: 3}, [{:s, :x, 1}, {:s, :y, 1}])
    assert next === %{s: {33_334, 1024, 3, false}, x: {33_333, 1024, 2, false}, y: {33_333, 1024, 2, false}}
    assert Enum.sum(for {_, {e, _, _, _}} <- next, do: e) === 100_000
    assert Enum.sum(for {_, {_, _, b, _}} <- next, do: b) === 7
  end

  # 累计取整的上界（Phase）：0 ≤ v ≤ q·S 时每笔 ∈ [0, u·S]、源格余数 ∈ [0, 留下单位·S]；S 为完整度 1024、已烧 2^18。
  defp assert_in_range(next, units) do
    for {cell, u} <- units do
      {_e, integrity, burnt, _fire} = next[cell]
      assert integrity >= 0 and integrity <= u * 1024
      assert burnt >= 0 and burnt <= u * 262_144
    end
  end

  test "将近烧尽、将近满 HP 的格一阶段分三笔外流：累计取整，每格剩余燃料与 HP 比例都在范围内" do
    # q = 7，S = 2^18 = 262 144：已烧 v = 7S − 1 = 1 835 007（只剩 1 个燃料单位），完整度 7·1024 − 1 = 7167，能量 700 µJ。
    # 同一阶段流向 a、b、c 各 3、2、1 单位（目标键序 a < b < c），源格留 1 单位。累计 C = 3、5、6：
    #   已烧 c_k = v·C/7 = C·S − C/7 → floor = 3S−1 = 786 431、5S−1 = 1 310 719、6S−1 = 1 572 863；
    #     各笔 786 431、524 288 = 2S、262 144 = S；源留 v − (6S−1) = S = 262 144（剩余燃料 0）。
    #   完整度 c_k = 7167·C/7 → 3071、5119、6143；各笔 3071、2048、1024；源留 7167 − 6143 = 1024。
    #   能量 700·C/7 = 300、500、600；各笔 300、200、100；源留 100。
    # 逐笔 floor 会给 b 524 287、c 262 143，源留 S + 2（剩余燃料 −2 单位），完整度源留 1026 > 1024；
    # 逐笔 ceil 会给 a 3S、源留 S − 1，完整度 a 3072、源留 1023。两者都与下式不等。
    values = %{s: {700, 7167, 1_835_007, true}}
    next = Phase.transport(values, %{s: 7}, [{:s, :a, 3}, {:s, :b, 2}, {:s, :c, 1}])
    assert next === %{s: {100, 1024, 262_144, true}, a: {300, 3071, 786_431, true},
      b: {200, 2048, 524_288, true}, c: {100, 1024, 262_144, true}}
    assert_in_range(next, %{s: 1, a: 3, b: 2, c: 1})
    for {cell, u} <- %{s: 1, a: 3, b: 2, c: 1} do
      row = Phase.restore(%{material: 30, hp: 50.0, max_hp: 50.0}, next[cell], u, 8, @burn_materials, 293.15)
      assert row.remaining_fuel_j >= 0.0
      assert row.hp <= row.max_hp
    end
    # 只有 a 还剩 1 个燃料单位并继续燃烧；源格与 b、c 全烧、熄灭。
    assert Phase.restore(%{material: 30, hp: 50.0, max_hp: 50.0}, next.a, 3, 8, @burn_materials, 293.15).burning
    refute Phase.restore(%{material: 30, hp: 50.0, max_hp: 50.0}, next.s, 1, 8, @burn_materials, 293.15).burning
  end

  test "镜像：几乎全损、几乎未烧的格一阶段分三笔外流，完整度与已烧不为负" do
    # q = 7，完整度 v = 2、已烧 v = 2（剩余燃料 7S − 2），能量 700 µJ；流向 a、b、c 各 3、2、1 单位，累计 C = 3、5、6：
    #   c_k = 2·C/7 = 6/7、10/7、12/7 → floor 0、1、1；各笔 0、1、0；源留 2 − 1 = 1。能量同上 300、200、100，源留 100。
    # 逐笔 floor 会给 0、0、0（源留 2）；逐笔 ceil 会给 1、1、1，源留 −1（完整度、已烧为负）。两者都与下式不等。
    values = %{s: {700, 2, 2, false}}
    next = Phase.transport(values, %{s: 7}, [{:s, :a, 3}, {:s, :b, 2}, {:s, :c, 1}])
    assert next === %{s: {100, 1, 1, false}, a: {300, 0, 0, false}, b: {200, 1, 1, false}, c: {100, 0, 0, false}}
    assert_in_range(next, %{s: 1, a: 3, b: 2, c: 1})
  end

  test "读行边界：剩余燃料不足半个燃料单位读作全烧，恰为一个单位读作剩一个单位" do
    # q = 4：满燃料 4·2^18 = 1 048 576 个燃料单位。剩余比例 0.4/1 048 576 → round(0.4) = 0 → 已烧 = 满燃料；
    # 剩余比例 1/1 048 576 → round(1.0) = 1 → 已烧 = 满燃料 − 1。能量 1.5 J → 1 500 000 µJ，完整度 4 → 4096。
    full = 4 * 262_144
    assert Phase.quantize({1.5, 4.0, 0.4 / full, true}, 4) === {1_500_000, 4096, full, true}
    assert Phase.quantize({1.5, 4.0, 1 / full, true}, 4) === {1_500_000, 4096, full - 1, true}
    # 未初始化燃料（火为 nil）不读比例，已烧恒为 0。
    assert Phase.quantize({0.0, 4.0, nil, nil}, 4) === {0, 4096, 0, nil}
    # 写回：全烧格剩余燃料恰为 0 且熄灭；剩一个单位的格剩余 = 满燃料 J / 2^20 > 0。
    materials = @burn_materials
    row = %{material: 30, hp: 50.0, max_hp: 50.0}
    burnt = Phase.restore(row, {0, 4096, full, true}, 4, 8, materials, 293.15)
    assert burnt.remaining_fuel_j == 0.0 and burnt.burning == false and burnt.power_w == 0.0
    one = Phase.restore(row, {0, 4096, full - 1, true}, 4, 8, materials, 293.15)
    # 满燃料 J = 1.5e7 × 4/8 = 7.5e6；一个单位 = 7.5e6 / 1 048 576。
    assert one.remaining_fuel_j == 7.5e6 / full
    assert one.burning
  end
end
