defmodule VoxelRegion.TestSupport.WorldClock do
  @moduledoc "只测试：每个 World 独占的单调毫秒与 timer 运输；不保存或修改物理状态。"
  use Agent

  def start_link(now), do: Agent.start_link(fn -> %{now: now, timers: %{}, serial: 0} end)
  def now(clock), do: Agent.get(clock, & &1.now)

  def schedule(clock, pid, message, delay) do
    Agent.get_and_update(clock, fn state ->
      timer = make_ref()
      entry = {state.now + delay, state.serial, pid, message}
      timers = if delay == 0 do
        send(pid, message)
        state.timers
      else
        Map.put(state.timers, timer, entry)
      end
      {timer, %{state | timers: timers, serial: state.serial + 1}}
    end)
  end

  def cancel(clock, timer) do
    Agent.get_and_update(clock, fn state ->
      {entry, timers} = Map.pop(state.timers, timer)
      result = if entry, do: max(elem(entry, 0) - state.now, 0), else: false
      {result, %{state | timers: timers}}
    end)
  end

  def cancel_all(clock), do: Agent.update(clock, &%{&1 | timers: %{}})

  def advance(clock, milliseconds) when milliseconds >= 0 do
    Agent.get_and_update(clock, fn state ->
      now = state.now + milliseconds
      {due, future} = Enum.split_with(state.timers, fn {_, {at, _, _, _}} -> at <= now end)
      due |> Enum.sort_by(fn {_, {at, serial, _, _}} -> {at, serial} end)
      |> Enum.each(fn {_, {_, _, pid, message}} -> send(pid, message) end)
      {now, %{state | now: now, timers: Map.new(future)}}
    end)
  end
end
