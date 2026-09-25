defmodule SceneServer.Body.ContactTest do
  @moduledoc """
  只测试：魔法增量 4 的身体后果——World 回传的接触热（导热按 `VoxelRegion.BodyContact` 手算，World 侧的回传与两端
  同值见 voxel_region `body_contact_world_test`）喂进 `Body.Thermo` 后的烧伤、生命、核心与浸没（Voxim Docs/Magic.md §6）。

  手算导热：鞋底踩木 0.03/(0.06 + 0.5/150) = 0.473684 W/K；0 °C 水全身浸没 1.8/(0.03 + 1/100) = 45 W/K；
  手碰 r 0.4 m 拟态 0.01/(0.4/400) = 10 W/K。每秒 q = G·(T_接触 − T_皮)（皮肤在 1 s 内变化 < 1 K，按步首值）。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Body.Thermo
  alias VoxelRegion.BodyContact

  @c 273.15
  @air 293.15

  defp tick(body, g, contact_k, immersed \\ 0.0) do
    q = g * (contact_k - body.skin_k)
    {body, account} = Thermo.step(body, 1.0, %{q_j: q, max_contact_k: contact_k, air_k: @air, immersed: immersed})
    {body, account}
  end

  defp run(body, g, contact_k, seconds, immersed \\ 0.0),
    do: Enum.reduce(1..seconds, body, fn _, b -> tick(b, g, contact_k, immersed) |> elem(0) end)

  defp air(body, seconds),
    do: Enum.reduce(1..seconds, body, fn _, b -> Thermo.step(b, 1.0, %{q_j: 0.0, max_contact_k: @air, air_k: @air}) |> elem(0) end)

  defp severity(body, tag), do: Enum.find_value(Body.injuries(body), 0, &(&1.tag == tag && &1.severity))

  test "站在 600 K 燃木上：1 s 即三度烧伤，循环受烧伤上限 0.7 → 生命 100 → 70；离开 5 分钟烧伤与生命不回" do
    g = BodyContact.sole(150, 0.5)
    assert_in_delta g, 0.4736842105, 1.0e-9
    {burnt, account} = tick(Body.new(), g, 600.0)
    # q = 0.4736842·(600 − 307.15) = 138.7184 J（1 s）
    assert_in_delta account.q_j, 138.71842, 1.0e-4
    assert severity(burnt, "trauma.thermal.burn") == 3
    assert Body.systems(burnt).circulation == 0.7
    assert Body.life(burnt) == 70
    assert burnt.status == :alive

    rested = air(run(burnt, g, 600.0, 9), 300)
    assert severity(rested, "trauma.thermal.burn") == 3
    assert Body.life(rested) == 70
    assert severity(rested, "temperature.hyperthermia") == 0
  end

  test "二度烧伤（剂量 2.5..5）：循环上限 0.9 → 生命 90" do
    assert Body.life(%{Body.new() | burn_dose_s: 3.0}) == 90
    assert Body.life(%{Body.new() | burn_dose_s: 1.0}) == 100
  end

  test "手碰 2000 K 拟态 1 s：q = 10·(2000 − 307.15) = 16928.5 J，三度烧伤；皮肤按手算升温" do
    g = BodyContact.touch(0.4, 400)
    {touched, account} = tick(Body.new(), g, 2000.0)
    assert_in_delta account.q_j, 16_928.5, 1.0e-6
    assert severity(touched, "trauma.thermal.burn") == 3
    # 皮肤 +(16928.5 + 22.69242·2.8 − 6.3558170·14)/24430（同 thermo_test 调定点项）
    assert_in_delta touched.skin_k - (34.0 + @c), (16_928.5 + 63.538776 - 88.981438) / 24_430, 1.0e-6
  end

  test "0 °C 水全身浸没（G 45 W/K、浸没 1.0）：皮肤骤降、寒战升高、核心下降；Gagge 两节点下寒战托住核心，1 小时不出现体温过低" do
    g = BodyContact.immersion(1.8, 1.8, 1.8)
    assert_in_delta g, 45.0, 1.0e-9
    {first, account} = tick(Body.new(), g, @c, 1.0)
    # q = 45·(273.15 − 307.15) = −1530 J；浸没时空气干热与出汗为 0
    assert_in_delta account.q_j, -1530.0, 1.0e-9
    assert account.convection_j == 0.0 and account.sweat_j == 0.0
    assert first.skin_k < 34.0 + @c

    ten = run(Body.new(), g, @c, 600, 1.0)
    assert ten.skin_k - @c < 15.0
    {_, account} = tick(ten, g, @c, 1.0)
    # 寒战 = 19.4·冷皮肤·冷核心·1.8（体温调节功能满值），10 分钟时已达数十瓦
    shiver = 19.4 * (34.0 + @c - ten.skin_k) * (36.8 + @c - ten.core_k) * 1.8
    assert_in_delta account.metabolic_j, 104.76 + shiver, 1.0e-6
    assert shiver > 50

    hour = run(ten, g, @c, 3000, 1.0)
    assert hour.core_k < 36.8 + @c - 0.1
    # 已知局限（body/README.md）：血管收缩后核心→皮肤导热约 10.7 W/K，37 K 温差下失热约 400 W，
    # 低于静息 + 寒战峰值 524 W，核心稳定在约 36.58 °C；世界里没有 0 °C 以下的液体，失温在现有内容下不可达。
    assert hour.core_k > 36.5 + @c
    assert severity(hour, "temperature.hypothermia") == 0
  end

  test "report：有变化才发的比较键（温度取 0.1 K）与状态码" do
    r = Body.report(Body.new())
    assert {r.life, r.status, r.injuries} == {100, 0, []}
    at = &Body.report(%{Body.new() | skin_k: &1}).key
    assert at.(307.0) == at.(307.03)
    refute at.(307.0) == at.(307.2)
    burnt = %{Body.new() | burn_dose_s: 6.0, status: :dying}
    assert %{life: 70, status: 1, injuries: [{"trauma.thermal.burn", 3}]} = Body.report(burnt)
  end
end
