defmodule MmoContracts.WorldTime do
  @moduledoc """
  分类：全局系统功能（世界基础设施）。服务端的游戏钟：把 Unix 微秒墙钟换算成昼夜日、日内分钟与星期。

  纯函数、整数微秒，不持有状态、不 tick、不持久化；任何节点对同一个 `t_us` 算出同一个值。
  定义（设计页 `docs/10-active/cross-cutting/2026-11-13-world-clock-design.md` §2）：

      game_us(t) = game0 + (t - epoch_us) * rate

  参数三元组取客户端现行冻结值（第一阶段不改协议，常量在客户端与服务端各一份，靠设计页 §3 的同一组手算值对账）：
  `epoch_us = 1_792_972_800_000_000`（2026-10-26T00:00Z）、`game0` = 6 小时、`rate` = 72（现实 20 分钟 = 一个昼夜日）。
  客户端公式出处：Voxim `Source/Voxim/Weather/VoxelWeather.cpp` 的 `HourOfDay`，
  客户端对账用例 `Voxim.Weather.WorldClockReconcile`（Voxim main `93a9cb27`，与本模块测试断言同一组手算值）与
  `Source/VoximTestOnly/Tests/VoxelWeatherTests.cpp` 的 `Voxim.Weather.Clock`，设计 `Docs/Weather.md` 昼夜时钟一行与实际作者值。

  派生量用向下取整除法，纪元之前也成立。月份与季节取天气日历，有调用方再接。
  """

  @minute_us 60_000_000
  @day_us 24 * 60 * @minute_us

  @params %{epoch_us: 1_792_972_800_000_000, game0: 6 * 60 * @minute_us, rate: 72}

  @doc "参数三元组 `%{epoch_us:, game0:, rate:}`（微秒、微秒、倍率）。"
  def params, do: @params

  @doc "游戏时间（微秒，自游戏零点起，可为负）。"
  def game_us(t_us, %{epoch_us: epoch_us, game0: game0, rate: rate} \\ @params),
    do: game0 + (t_us - epoch_us) * rate

  @doc "昼夜日号 `day`、日内分钟 `minute_of_day`（0..1439）与星期 `weekday`（0..6，`day` 对 7 取模）。"
  def at(t_us, params \\ @params) do
    game = game_us(t_us, params)
    day = Integer.floor_div(game, @day_us)

    %{
      day: day,
      minute_of_day: game |> Integer.mod(@day_us) |> div(@minute_us),
      weekday: Integer.mod(day, 7)
    }
  end
end
