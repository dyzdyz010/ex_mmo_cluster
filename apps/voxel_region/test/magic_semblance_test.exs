defmodule VoxelRegion.MagicSemblanceTest do
  @moduledoc """
  只测试：拟态纯几何弹道（`Magic.Semblance` 的 `position/4`、`current/1`、`trace/7-8`、`flight_segments/2`、`spent?/1`），
  包含 Hello 45 无重力直线飞行与有重力抛物线对照。

  v1 形态造价与旧拟态构造（`new/4`、`form_j/3`、`kinetic_j/2`）已随切片 3 删除；拟态几何与弹道留作切片 4 结构物理体，
  本文件保留其纯值回归。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.Semblance

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

  # 平顶 y = 5 以上全是实占用：线段穿过 y = 5 时返回穿越点所在的 y = 5 层（微格 y = 40）微格。
  defp ceiling(origin, {dx, dy, dz}, length, state) do
    {x, y, z} = origin

    if dy > 0 and y + dy * length > 5.0 do
      s = (5.0 - y) / dy
      {{:ceiling, {floor((x + dx * s) * 8), 40, floor((z + dz * s) * 8)}}, state + 1}
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
    assert {{:free, {+0.0, 1.0, 0.5}}, _} =
             Semblance.trace(
               {0.0, 1.0, 0.0},
               {0.0, 1.0, 0.5},
               {0.0, 0.0, 0.0},
               0.1,
               30.0,
               0,
               &ground/4
             )

    assert {{:hit, +0.0, {_, 0.1, _}, :ground}, _} =
             Semblance.trace(
               {0.0, 0.2, 0.0},
               {0.0, -0.3, 0.0},
               {0.0, 0.0, 0.0},
               0.1,
               30.0,
               0,
               &ground/4
             )

    # 竖直上抛 30 m/s：30 m 路程内不落地 → miss，并给出射程端点时刻。上升段弦长之和 = 升高 30t − ½·9.81·t²，
    # 达 30 m 于 t = (30 − √(900 − 588.6)) / 9.81 = 1.2593 s；按 0.05 s 弦段在第 26 段末（t = 1.30 s）首次达到。
    assert {{:miss, t}, _} =
             Semblance.trace(
               {0.0, 2.0, 0.0},
               {0.0, 2.0, 0.0},
               {0.0, 30.0, 0.0},
               0.25,
               30.0,
               0,
               &ground/4
             )

    assert_in_delta t, 1.30, 1.0e-12
  end

  test "无重力直线弹道：水平 30 m/s 飞行 0..1 s 零下坠（对照有重力下坠 4.905 m）；上下斜射 Y 面精确线性穿越" do
    origin = {0.0, 2.5, 0.0}
    velocity = {30.0, 0.0, 0.0}

    for t <- [0.0, 0.25, 0.5, 1.0] do
      assert {x, y, z} = Semblance.position(origin, velocity, t, true)
      assert_in_delta x, 30.0 * t, 1.0e-12
      assert y == 2.5
      assert z == 0.0
    end

    assert {30.0, y_drop, +0.0} = Semblance.position(origin, velocity, 1.0, false)
    assert_in_delta y_drop, 2.5 - 0.5 * 9.81, 1.0e-12

    # current 与 flight_segments 遵循 no_gravity；缺省按有重力处理。
    straight = %{
      origin: origin,
      velocity: velocity,
      age_s: 0.0,
      flight_s: 1.0,
      rest: {30.0, 2.5, 0.0},
      no_gravity: true
    }

    parabolic = Map.delete(straight, :no_gravity)
    assert Semblance.current(%{straight | age_s: 0.5}) == {15.0, 2.5, 0.0}
    assert {15.0, y_mid, +0.0} = Semblance.current(%{parabolic | age_s: 0.5})
    assert_in_delta y_mid, 2.5 - 0.5 * 9.81 * 0.25, 1.0e-12

    segs = Semblance.flight_segments(straight, 1.0)
    assert length(segs) == 20
    assert Enum.all?(segs, fn {_, _, {_, ay, _}, {_, by, _}} -> ay == 2.5 and by == 2.5 end)
    {_, _, _, {_, end_y, _}} = List.last(Semblance.flight_segments(parabolic, 1.0))
    assert_in_delta end_y, 2.5 - 4.905, 1.0e-12

    # 水平 30 m/s 经 trace 扫过平地 y = 0：无重力直线全程不落地（30 m 处 miss，t = 1.0 s）；有重力命中地面。
    assert {{:miss, t_miss}, _} =
             Semblance.trace(origin, origin, velocity, 0.05, 30.0, 0, &ground/4, true)

    assert_in_delta t_miss, 1.0, 1.0e-12

    assert {{:hit, t_fall, {_, 0.05, _}, :ground}, _} =
             Semblance.trace(origin, origin, velocity, 0.05, 30.0, 0, &ground/4, false)

    assert_in_delta t_fall, :math.sqrt(2 * 2.5 / 9.81), 1.0e-6

    # 向下斜射 Y 面 y = 0：y(t) = 2.1 − 4t = 0 → t = 0.525 s，x = 0.01 + 3 × 0.525 = 1.585 m，球心停在 y = 0.25 m。
    assert {{:hit, t_down, {xd, yd, zd}, :ground}, _} =
             Semblance.trace(
               {0.01, 2.1, 0.0},
               {0.01, 2.1, 0.0},
               {3.0, -4.0, 0.0},
               0.25,
               30.0,
               0,
               &ground/4,
               true
             )

    assert_in_delta t_down, 0.525, 1.0e-12
    assert_in_delta xd, 1.585, 1.0e-12
    assert yd == 0.25 and zd == 0.0

    # 向上斜射 Y 面 y = 5：y(t) = 1.85 + 6t = 5 → t = 0.525 s，x = 0.01 + 3 × 0.525 = 1.585 m，球心停在 y = 4.75 m。
    assert {{:hit, t_up, {xu, yu, zu}, :ceiling}, _} =
             Semblance.trace(
               {0.01, 1.85, 0.0},
               {0.01, 1.85, 0.0},
               {3.0, 6.0, 0.0},
               0.25,
               30.0,
               0,
               &ceiling/4,
               true
             )

    assert_in_delta t_up, 0.525, 1.0e-12
    assert_in_delta xu, 1.585, 1.0e-12
    assert yu == 4.75 and zu == 0.0
  end

  test "spent?/1：无接触且有初速的拟态到达射程端点后散解，静止或有接触的不散解" do
    base = %{velocity: {30.0, 0.0, 0.0}, contact: nil, flight_s: 1.0, age_s: 1.0}
    assert Semblance.spent?(base)
    refute Semblance.spent?(%{base | age_s: 0.5})
    refute Semblance.spent?(%{base | contact: %{cell: {0, 0, 0}}})
    refute Semblance.spent?(%{base | velocity: {0.0, 0.0, 0.0}, flight_s: 0.0, age_s: 0.0})
  end
end
