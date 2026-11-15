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
end
