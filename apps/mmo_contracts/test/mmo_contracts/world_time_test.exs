defmodule MmoContracts.WorldTimeTest do
  @moduledoc """
  只测试：游戏钟纯函数。期望来自设计页 §3 的手算表（现实 150 秒 = 游戏 1 小时，现实 60 分钟 = 一个昼夜日，
  纪元 06:00；2026-11-15 起 ×24，此前是 ×72，表里的值已按 ×24 手算重写），同一组值也是客户端 `HourOfDay` 在同输入下的值
  （客户端对账用例 `Voxim.Weather.WorldClockReconcile` 与 `VoxelWeatherTests.cpp` 的 `Voxim.Weather.Clock`，需随客户端常量同步改成同一组值）。
  客户端没有日号与 weekday，这两列只在此断言。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.WorldTime

  @epoch 1_792_972_800_000_000
  @sec 1_000_000
  @real_day 60 * 60 * @sec

  # {t 相对纪元的偏移（微秒）, day, 时, 分, weekday}
  # 现实 150 秒 = 游戏 1 小时；现实 45 分钟 = 游戏 18 小时（06:00 + 18 小时 = 次日 00:00）。
  @cases [
    {0, 0, 6, 0, 0},
    {150 * @sec, 0, 7, 0, 0},
    {45 * 60 * @sec, 1, 0, 0, 1},
    {@real_day, 1, 6, 0, 1},
    {7 * @real_day, 7, 6, 0, 0},
    {-150 * @sec, 0, 5, 0, 0},
    {-@real_day, -1, 6, 0, 6}
  ]

  test "参数三元组是客户端现行冻结值" do
    assert WorldTime.params() == %{epoch_us: @epoch, game0: 6 * 3_600 * @sec, rate: 24}
  end

  for {offset, day, hour, minute, weekday} <- @cases do
    test "纪元#{if offset >= 0, do: "+", else: ""}#{offset} 微秒：day #{day}、#{hour}:#{minute}、weekday #{weekday}" do
      assert WorldTime.at(@epoch + unquote(offset)) == %{
               day: unquote(day),
               minute_of_day: unquote(hour) * 60 + unquote(minute),
               weekday: unquote(weekday)
             }
    end
  end

  test "game_us 在纪元为 game0，之后每现实 1 秒走 24 游戏秒" do
    assert WorldTime.game_us(@epoch) == 6 * 3_600 * @sec
    assert WorldTime.game_us(@epoch + 1 * @sec) - WorldTime.game_us(@epoch) == 24 * @sec
  end

  # ---------- Test-only 世界钟偏移（设计页“Test-only 偏移”一节）：游戏时间 = at(墙钟 + 偏移) ----------
  # 墙钟取纪元后 50 分钟：未偏移时 3000 秒 × 24 = 游戏 20 小时，06:00 + 20 小时 = day 1、02:00。
  @wall @epoch + 50 * 60 * @sec

  # {VOXIM_TEST_WORLD_CLOCK_OFFSET_S 原值, day, 时, 分, weekday}；墙钟 + 偏移后按上面同一换算手算。
  @offset_cases [
    # 未设：偏移 0，即未偏移值。
    {nil, 1, 2, 0, 1},
    {"0", 1, 2, 0, 1},
    # +600 秒：墙钟 + 偏移 = 纪元后 60 分钟 = 一个昼夜日 → day 1、06:00（驱动要的“落在游戏日开头”）。
    {"600", 1, 6, 0, 1},
    # 带正号同义；+75 秒：纪元后 3075 秒 × 24 = 20.5 小时 → 02:30。
    {"+75", 1, 2, 30, 1},
    # −3000 秒：回到纪元 → day 0、06:00。
    {"-3000", 0, 6, 0, 0},
    # −7200 秒：纪元前 4200 秒 × 24 = −28 小时，06:00 − 28 小时 = 前一日 02:00 → day −1、weekday 6（向下取整）。
    {"-7200", -1, 2, 0, 6}
  ]

  for {raw, day, hour, minute, weekday} <- @offset_cases do
    test "偏移 #{inspect(raw)} 秒：纪元后 50 分钟的墙钟落在 day #{day}、#{hour}:#{minute}、weekday #{weekday}" do
      assert WorldTime.at(@wall + WorldTime.test_offset_us!(unquote(raw))) == %{
               day: unquote(day),
               minute_of_day: unquote(hour) * 60 + unquote(minute),
               weekday: unquote(weekday)
             }
    end
  end

  test "偏移为 0（未设或 \"0\"）时，§3 表逐行同值，参数三元组不变" do
    for raw <- [nil, "0"], {offset, day, hour, minute, weekday} <- @cases do
      assert WorldTime.at(@epoch + offset + WorldTime.test_offset_us!(raw)) == %{
               day: day,
               minute_of_day: hour * 60 + minute,
               weekday: weekday
             }
    end

    assert WorldTime.params() == %{epoch_us: @epoch, game0: 6 * 3_600 * @sec, rate: 24}
  end

  test "偏移原值不是十进制整数秒：raise，消息带变量名与原值" do
    for raw <- ["", " 600", "600 ", "1.5", "600s", "10m", "0x10", "abc"] do
      error = assert_raise ArgumentError, fn -> WorldTime.test_offset_us!(raw) end
      assert error.message =~ "VOXIM_TEST_WORLD_CLOCK_OFFSET_S"
      assert error.message =~ inspect(raw)
    end
  end
end
