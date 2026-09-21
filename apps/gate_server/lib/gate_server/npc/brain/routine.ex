defmodule GateServer.Npc.Brain.Routine do
  @moduledoc """
  全局系统功能：决策树后端的退化形式——按作者给定的顺序逐条发命令，上一条有了 Outcome 才发下一条，被拒也继续，
  走完即停。`target: :probe` 的步骤取最近一次成功探测返回的目标身份。纯函数，无进程、无时钟（用 Observation 的 tick）。

  profile: `%{steps: [不带 id 的 Command, ...]}`
  """
  @behaviour GateServer.Npc.Brain

  # 两条命令之间的 tick 数；服务端按工具 interval 做速率裁决，这里只是不去撞它。
  @gap 36

  @impl true
  def init(%{steps: steps}), do: %{steps: steps, waiting: nil, ready_at: 0, tick: 0, probe: nil, next_id: 1}

  @impl true
  def handle_event(
        {:observation, %{self: %{tick: tick}}},
        %{waiting: nil, steps: [step | rest], ready_at: ready_at, next_id: id} = state
      )
      when tick >= ready_at do
    step = if Map.get(step, :target) == :probe, do: %{step | target: state.probe}, else: step
    {[Map.put(step, :id, id)], %{state | steps: rest, waiting: id, tick: tick, next_id: id + 1}}
  end

  def handle_event({:observation, %{self: %{tick: tick}}}, state), do: {[], %{state | tick: tick}}

  def handle_event({:outcome, %{id: id} = outcome}, %{waiting: id} = state) do
    probe = if match?(%{verb: :probe_toward, status: :done}, outcome), do: outcome.data, else: state.probe
    {[], %{state | waiting: nil, probe: probe, ready_at: state.tick + @gap}}
  end

  def handle_event({:outcome, _}, state), do: {[], state}
end
