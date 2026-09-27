defmodule SceneServer.Body.ContactTest do
  @moduledoc """
  只测试：身体接触后果——World 回传的接触热与局部接触组织块热（导热按 `VoxelRegion.BodyContact` 手算，World 热内核对同一
  组织块的数值积分与两端同值见 voxel_region `body_contact_world_test`）喂进 `Body.Thermo` 后的烧伤、冻伤、生命与浸没
  （Voxim Docs/Magic.md §6）。

  World 的角色由解析解替身扮演（每秒一段，段内世界格温度 T_w 与皮肤温度 T_s 视为常数）：组织块热容 C_t = 209.4 J/K，
  接触导热 G_c，组织块-皮肤导热 G_i = 0.03 m² × K_t（本步组织块导热 `Thermo.contact_tissue_w_per_m2_k/1`）：
    k = (G_c + G_i)/C_t，T_ss = (G_c·T_w + G_i·T_s)/(G_c + G_i)，T_末 = T_ss + (T_0 − T_ss)·e^(−k)；
    tissue_j = C_t·(T_末 − T_0)，q = G_c·[(T_w − T_ss) + (T_ss − T_0)·(1 − e^(−k))/k]。

  手算导热：冬靴踩木 0.03/(0.15 + 0.5/150) = 0.1956522 W/K，赤脚 0.03/(0.5/150) = 9 W/K；冬靴踩冰（k 22）
  0.03/(0.15 + 0.5/22) = 0.1736842 W/K，赤脚 0.03/(0.5/22) = 1.32 W/K；手碰 r 0.4 m 拟态 0.01/(0.4/400) = 10 W/K；
  0 °C 水全身浸没 1.8877/(0.03 + 1/100) = 47.1925 W/K（浸没接皮肤，不经组织块）。
  调定点身体 K_t = 5.28 + 1.163 × 6.3 = 12.6069 → G_i = 0.378207 W/K。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Thermo
  alias VoxelRegion.BodyContact

  @c 273.15
  @air 293.15
  @wood 150.0
  @ice 22.0

  # 一秒接触：解析解替身给出 q 与 tissue_j，再推进身体；每步核对身体能量账（各节点 + 组织块）。
  defp contact_step(body, g_c, t_w) do
    c_t = Body.tissue_capacity_j_per_k()
    g_i = Body.params().contact_tissue_m2 * Thermo.contact_tissue_w_per_m2_k(body)
    k = (g_c + g_i) / c_t
    ss = (g_c * t_w + g_i * body.skin_k) / (g_c + g_i)
    decay = :math.exp(-k)
    tissue_j = c_t * (ss + (body.tissue_k - ss) * decay - body.tissue_k)
    q = g_c * ((t_w - ss) + (ss - body.tissue_k) * (1 - decay) / k)
    {next, account} = Thermo.step(body, 1.0, %{q_j: q, tissue_j: tissue_j, air_k: @air})

    assert_in_delta account.stored_j, Body.heat_content_j(next) - Body.heat_content_j(body), 1.0e-6
    next
  end

  defp scenario(g_c, t_w, seconds), do: Enum.scan(1..seconds, Body.new(), fn _, b -> contact_step(b, g_c, t_w) end)

  # 第一个满足条件的秒（1 起）；没有为 nil。
  defp first(states, f), do: Enum.find_index(states, f) |> then(&(&1 && &1 + 1))
  defp severity(body, tag), do: Enum.find_value(Body.injuries(body), 0, &(&1.tag == tag && &1.severity))
  defp burn(body), do: severity(body, "trauma.thermal.burn")

  test "组织块参数：0.06 kg × 3490 = 209.4 J/K；调定点 G_i = 0.03 × 12.6069 = 0.378207 W/K" do
    assert_in_delta Body.tissue_capacity_j_per_k(), 209.4, 1.0e-9
    assert_in_delta Body.params().contact_tissue_m2 * Thermo.contact_tissue_w_per_m2_k(Body.new()), 0.378207, 1.0e-9
  end

  # 冬靴站 1296 K 燃木：T_ss = (0.1956522·1296 + 0.378207·307.15)/0.5738592 = 644.29 K，k = 0.5738592/209.4 = 0.0027405 /s；
  # 44 °C（317.15 K）：e^(−kt) = (644.29 − 317.15)/337.14 → t ≈ 11.0 s；60 °C：t ≈ 29.3 s。近 60 °C 时组织块每秒约升 0.87 K，
  # 剂量率每 1.52 s 翻倍，累计剂量 ≈ 2.73 × 当前剂量率 → 1 / 2.5 / 5 分别在 331.2 / 333.0 / 334.3 K，即约第 28 / 30 / 31 秒。
  # 皮肤每秒只多得约 0.2 W/K × 1000 K ≈ 190 W，30 s 内升不到 0.3 K，对 T_ss 的影响 < 0.2 K。
  test "冬靴站 1296 K 燃木：组织块逐秒升温，约 11 s 过 44 °C，一、二、三度烧伤约在第 28、30、31 秒依次出现" do
    states = scenario(BodyContact.sole(@wood, 0.5), 1296.0, 60)
    warm = first(states, &(&1.tissue_k >= 44.0 + @c))
    degrees = for d <- 1..3, do: first(states, &(burn(&1) >= d))
    IO.puts("BURN_BOOTED tissue_44c_s=#{warm} degree_s=#{inspect(degrees)} tissue_k_at_30s=#{Enum.at(states, 29).tissue_k}")
    assert warm in 10..12
    assert Enum.all?(Enum.take(states, warm - 1), &(&1.burn_dose_s == 0.0))
    [d1, d2, d3] = degrees
    assert d1 in 26..30 and d2 in 28..32 and d3 in 29..33 and d1 <= d2 and d2 <= d3
    # 本场景只推进 Thermo（急性期计时由 Repair.tick 推进，见 repair_test）：进三度那一刻计时 0 → 上限 1、生命 100；
    # 同一身体急性期满（30 s）→ 上限 1 − 0.090906 = 0.909094 → 生命 91
    third = Enum.at(states, d3 - 1)
    assert Body.life(third) == 100
    assert Body.life(%{third | burn_age_s: 30.0}) == 91
  end

  # 赤脚（无鞋底热阻）：G_c = 9 W/K，T_ss = (9·1296 + 0.378207·307.15)/9.378207 = 1256.1 K，k = 0.0447861 /s；
  # 第 1 秒末 T = 1256.12 − 948.97·e^(−0.0447861) = 348.71 K（75.6 °C），剂量率 2^((348.6 − 333.15)/1.32) ≈ 3.3e3 → 第 1 秒即三度。
  test "赤脚站 1296 K 燃木：第 1 秒组织块已 75 °C、即三度烧伤（冬靴约 31 秒）" do
    [one | _] = scenario(0.03 / (0.5 / @wood), 1296.0, 3)
    assert_in_delta one.tissue_k, 348.71, 0.05
    assert burn(one) == 3
  end

  # 手碰 2000 K 拟态（替身里拟态温度恒定；真实拟态以辐射急速冷却，只会更慢）：G_c = 10 W/K，T_ss = 1938.31 K，
  # k = 0.0495616 /s，第 1 秒末 T = 1938.31 − 1631.16·e^(−0.0495616) = 386.02 K → 第 1 秒三度。
  test "徒手触 2000 K 拟态：第 1 秒组织块 386 K、即三度烧伤；皮肤只得组织块送来的一小部分热" do
    [one | _] = scenario(BodyContact.touch(0.4, 400), 2000.0, 1)
    assert_in_delta one.tissue_k, 386.02, 0.05
    assert burn(one) == 3
    assert one.skin_k - (34.0 + @c) < 0.01
  end

  # 冬靴站 −25 °C 冰（暖区里一块冷冰，偏离环境才进 World 内核）：T_ss = (0.1736842·248.15 + 0.378207·307.15)/0.5518912
  # = 288.58 K（15.4 °C）> 冻伤阈值 272.6 K → 永不冻伤。1 小时里身体在 20 °C 空气中略暖（核心约 36.9 °C → 皮肤血流舒张、G_i 变大，
  # 皮肤约 34.2 °C），稳态按末态的 G_i 与皮肤温度同一式重算。赤脚：G_c = 1.32，T_ss = (1.32·248.15 + 0.378207·307.15)/1.698207
  # = 261.29 K，k = 0.0081099 /s，降到 272.6 K：e^(−kt) = (272.6 − 261.29)/45.86 → t ≈ 173 s；再累计 600 K·s
  # （过冷差 11.31·(1 − e^(−kτ)) 的积分）τ ≈ 135 s → 约第 308 秒冻伤（皮肤 20 °C 空气下略降、血管收缩使 G_i 变小，只会略早）。
  test "站 −25 °C 冰：冬靴 1 小时不冻伤（组织块稳在约 15 °C）；赤脚约 5 分钟冻伤" do
    shod = scenario(BodyContact.sole(@ice, 0.5), 248.15, 3600)
    assert Enum.all?(shod, &(&1.frost_dose_k_s == 0.0))
    last = List.last(shod)
    g_i = Body.params().contact_tissue_m2 * Thermo.contact_tissue_w_per_m2_k(last)
    g_c = BodyContact.sole(@ice, 0.5)
    assert_in_delta last.tissue_k, (g_c * 248.15 + g_i * last.skin_k) / (g_c + g_i), 0.1
    assert last.tissue_k > 285.0

    bare = scenario(0.03 / (0.5 / @ice), 248.15, 600)
    below = first(bare, &(&1.tissue_k < 272.6))
    shallow = first(bare, &(severity(&1, "trauma.thermal.frostbite") >= 1))
    frost = first(bare, &(severity(&1, "trauma.thermal.frostbite") == 2))
    IO.puts("FROST_BAREFOOT below_onset_s=#{below} shallow_s=#{shallow} deep_s=#{frost}")
    assert below in 150..180 and below < shallow and shallow < frost and frost in 270..320
  end

  # 慢性深度 0.25 × √(92.5551 s / T)：1 度 0.25、2 度 0.151287（T 252.7405 s）、3 度 0.090906（T 699.9887 s），见 repair_test 手算
  test "未愈合烧伤急性期满（30 s）后压循环：1 / 2 / 3 度上限 0.75 / 0.848713 / 0.909094 → 生命 75 / 85 / 91" do
    assert Body.life(%{Body.new() | burn_dose_s: 1.0, burn_age_s: 30.0}) == 75
    assert Body.life(%{Body.new() | burn_dose_s: 3.0, burn_age_s: 30.0}) == 85
    assert Body.life(%{Body.new() | burn_dose_s: 6.0, burn_age_s: 30.0}) == 91
  end

  test "0 °C 水全身浸没（G 47.1925 W/K 接皮肤、浸没 1.0）：皮肤骤降、寒战升高、核心下降，1 小时内出现体温过低" do
    g = BodyContact.immersion(Body.params().area_m2, 1.8, 1.8)
    assert_in_delta g, 47.1925, 1.0e-9
    tick = fn b -> Thermo.step(b, 1.0, %{q_j: g * (@c - b.skin_k), air_k: @air, immersed: 1.0}) end
    {first, account} = tick.(Body.new())
    # q = 47.1925·(273.15 − 307.15) = −1604.545 J；浸没时空气干热、出汗与湿衣蒸发为 0
    assert_in_delta account.q_j, -1604.545, 1.0e-9
    assert account.convection_j == 0.0 and account.sweat_j == 0.0 and account.drying_j == 0.0
    assert first.skin_k < 34.0 + @c

    ten = Enum.reduce(1..600, Body.new(), fn _, b -> tick.(b) |> elem(0) end)
    assert ten.skin_k - @c < 20.0
    {_, account} = tick.(ten)
    # 寒战 = 需求（Tikuisis & Giesbrecht 1999）× 体表面积（体温调节功能满值、未到峰值）
    shiver = Thermo.shiver_demand_w_per_m2(ten) * Body.params().area_m2
    assert_in_delta account.shiver_j, shiver, 1.0e-9
    assert shiver > 150

    hour = Enum.reduce(1..3000, ten, fn _, b -> tick.(b) |> elem(0) end)
    # 实测对照（冷水浸泡 0–5 °C 核心 2–4 °C/h、约 40 分钟进入 35 °C 以下）见 cold_validation_test.exs
    assert severity(hour, "temperature.hypothermia") >= 1
    assert hour.wetness > 0.999
  end

  test "report：有变化才发的比较键（温度取 0.1 K）与状态码" do
    r = Body.report(Body.new(), 1.0)
    assert {r.life, r.status, r.injuries} == {100, 0, []}
    at = &Body.report(%{Body.new() | skin_k: &1}, 1.0).key
    assert at.(307.0) == at.(307.03)
    refute at.(307.0) == at.(307.2)
    burnt = %{Body.new() | burn_dose_s: 6.0, burn_age_s: 30.0, status: :dying}
    # Hello 29：伤病带愈合进度 %（未开始愈合为 0），下行带蛋白质储备（新身体满 100 g）；Hello 30：可恢复 9、剩余秒数（repair_test 手算）
    assert %{life: 91, recoverable: 9, status: 1, injuries: [{"trauma.thermal.burn", 3, 0, _}], protein_g: 100.0} =
             Body.report(burnt, 1.0)
  end
end
