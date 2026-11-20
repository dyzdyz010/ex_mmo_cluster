defmodule NpcServer.NpcRuntimeWorldTimeTest do
  @moduledoc """
  只测试：`Runtime` 交给 Brain 的观察带世界时间（`MmoContracts.WorldTime.at/1`），且按 Test-only 世界钟偏移换算。
  真实 `Runtime`，Brain 是只转发事件的替身；不启动 World、数据库或外部 HTTP。

  Runtime 直接读墙钟、没有可注入的时钟，所以这里不断言一个固定值，而是用调用前后的毫秒墙钟围出这次观察可能取到的
  全部时刻，断言世界时间等于其中某一刻的 `WorldTime.at/1`；具体的 (t → 日 / 时:分 / 星期) 对应与偏移的手算值由
  `mmo_contracts` 的 `world_time_test` 负责。

  偏移由 `config/runtime.exs` 写进 `:npc_server, :world_clock_test_offset_us`、Runtime 起来时读一次；偏移用例改这一项
  应用环境（全局），所以本模块不并发（`async: false`），用完恢复原值。
  """
  use ExUnit.Case, async: false
  alias MmoContracts.WorldTime

  defmodule Spy do
    def init(profile), do: profile

    def handle_event(event, state) do
      send(state.owner, {:event, event})
      {[], state}
    end
  end

  # 起一个 Runtime、喂一帧观察，回 {世界时间, 观察前后的毫秒墙钟区间}。
  defp observe_world_time do
    runtime = NpcServer.Runtime.init({Spy, %{owner: self()}})
    before_ms = System.system_time(:millisecond)
    NpcServer.Runtime.handle_event({:observation, %{self: %{entity_id: 1, tick: 1}}}, runtime)
    assert_receive {:event, {:observation, %{world_time: world_time}}}
    after_ms = System.system_time(:millisecond)
    {world_time, before_ms..after_ms}
  end

  # 把偏移设为给定值、用完恢复原值（开发者 shell 里可能还 export 着偏移变量，`config/runtime.exs` 会读进应用环境）。
  defp with_offset(offset_us) do
    previous = Application.get_env(:npc_server, :world_clock_test_offset_us)
    Application.put_env(:npc_server, :world_clock_test_offset_us, offset_us)
    on_exit(fn -> Application.put_env(:npc_server, :world_clock_test_offset_us, previous) end)
  end

  test "观察带世界时间，且是观察时刻的 WorldTime.at" do
    with_offset(0)
    {world_time, window} = observe_world_time()
    candidates = for ms <- window, do: WorldTime.at(ms * 1000)

    assert Map.keys(world_time) |> Enum.sort() == [:day, :minute_of_day, :weekday]
    assert world_time in candidates
  end

  test "Test-only 偏移：世界时间按“墙钟 + 偏移”换算，不是未偏移的值" do
    # +1800 秒 = 游戏 12 小时：与未偏移的日内分钟差 720，围出的窗口远短于 30 分钟，两组候选不相交。
    offset_us = 1_800 * 1_000_000
    with_offset(offset_us)

    {world_time, window} = observe_world_time()

    assert world_time in for(ms <- window, do: WorldTime.at(ms * 1000 + offset_us))
    refute world_time in for(ms <- window, do: WorldTime.at(ms * 1000))
  end
end
