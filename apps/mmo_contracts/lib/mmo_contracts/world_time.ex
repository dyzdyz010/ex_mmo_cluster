defmodule MmoContracts.WorldTime do
  @moduledoc """
  分类：全局系统功能（世界基础设施）。服务端的游戏钟：把 Unix 微秒墙钟换算成昼夜日、日内分钟与星期。

  纯函数、整数微秒，不持有状态、不 tick、不持久化；任何节点对同一个 `t_us` 算出同一个值。
  定义（设计页 `docs/10-active/cross-cutting/2026-11-13-world-clock-design.md` §2）：

      game_us(t) = game0 + (t - epoch_us) * rate

  参数三元组取客户端现行冻结值（第一阶段不改协议，常量在客户端与服务端各一份，靠设计页 §3 的同一组手算值对账）：
  `epoch_us = 1_792_972_800_000_000`（2026-10-26T00:00Z）、`game0` = 6 小时、`rate` = 24（现实 60 分钟 = 一个昼夜日，现实 150 秒 = 游戏 1 小时）。
  2026-11-15 由 72 改为 24：规划模型按游戏钟写的时限在 ×72 下现实里只有几十秒，太短（见设计页页首的更新说明）；
  客户端常量需同步改成 24，对账用例的手算值已按 ×24 重算。
  客户端公式出处：Voxim `Source/Voxim/Weather/VoxelWeather.cpp` 的 `HourOfDay`，
  客户端对账用例 `Voxim.Weather.WorldClockReconcile`（Voxim main `93a9cb27`，与本模块测试断言同一组手算值）与
  `Source/VoximTestOnly/Tests/VoxelWeatherTests.cpp` 的 `Voxim.Weather.Clock`，设计 `Docs/Weather.md` 昼夜时钟一行与实际作者值。

  派生量用向下取整除法，纪元之前也成立。月份与季节取天气日历，有调用方再接。

  **Test-only 世界钟偏移**（设计页“Test-only 偏移”一节）：实跑想让一轮落在游戏日开头时，部署可设
  `VOXIM_TEST_WORLD_CLOCK_OFFSET_S=<整数秒>`，`config/runtime.exs` 用 `test_offset_us!/1` 解析一次，写进
  `:npc_server, :world_clock_test_offset_us`；NPC `Runtime` 换算观察里的 `world_time` 时用 `at(墙钟 + 偏移)`。
  偏移只加在输入的墙钟上（同 Java `Clock.offset`），公式与 `params/0` 不变；两个时刻的游戏时间差与偏移无关。
  客户端昼夜不跟着偏移，开偏移时两端天色对不上（第二阶段服务端下发参数后才能一致）。生产 / 分发不得设置。
  """

  @minute_us 60_000_000
  @day_us 24 * 60 * @minute_us

  @params %{epoch_us: 1_792_972_800_000_000, game0: 6 * 60 * @minute_us, rate: 24}

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

  @doc """
  只测试：把环境变量 `VOXIM_TEST_WORLD_CLOCK_OFFSET_S` 的原值解析成偏移微秒。未设（`nil`）为 0；十进制整数秒
  （可带正负号，不带空白与单位）乘 10⁶；其余 raise `ArgumentError`，消息带变量名与原值。只由 `config/runtime.exs`
  在启动时调一次（格式不对即启动失败）。
  """
  def test_offset_us!(nil), do: 0

  def test_offset_us!(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {seconds, ""} ->
        seconds * 1_000_000

      _ ->
        raise ArgumentError,
              "VOXIM_TEST_WORLD_CLOCK_OFFSET_S 必须是十进制整数秒（可带正负号，不带空白与单位），实际为 #{inspect(raw)}"
    end
  end
end
