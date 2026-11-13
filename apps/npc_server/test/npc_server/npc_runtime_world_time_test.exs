defmodule NpcServer.NpcRuntimeWorldTimeTest do
  @moduledoc """
  只测试：`Runtime` 交给 Brain 的观察带世界时间（`MmoContracts.WorldTime.at/1`）。
  真实 `Runtime`，Brain 是只转发事件的替身；不启动 World、数据库或外部 HTTP。

  Runtime 直接读墙钟、没有可注入的时钟（本阶段不为此新增注入机制），所以这里不断言一个固定值，而是用调用前后的
  毫秒墙钟围出这次观察可能取到的全部时刻，断言世界时间等于其中某一刻的 `WorldTime.at/1`；
  具体的 (t → 日 / 时:分 / 星期) 对应由 `mmo_contracts` 的 `world_time_test` 的手算表负责。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.WorldTime

  defmodule Spy do
    def init(profile), do: profile

    def handle_event(event, state) do
      send(state.owner, {:event, event})
      {[], state}
    end
  end

  test "观察带世界时间，且是观察时刻的 WorldTime.at" do
    runtime = NpcServer.Runtime.init({Spy, %{owner: self()}})
    before_ms = System.system_time(:millisecond)
    NpcServer.Runtime.handle_event({:observation, %{self: %{entity_id: 1, tick: 1}}}, runtime)
    assert_receive {:event, {:observation, %{world_time: world_time}}}
    after_ms = System.system_time(:millisecond)

    candidates = for ms <- before_ms..after_ms, do: WorldTime.at(ms * 1000)

    assert Map.keys(world_time) |> Enum.sort() == [:day, :minute_of_day, :weekday]
    assert world_time in candidates
  end
end
