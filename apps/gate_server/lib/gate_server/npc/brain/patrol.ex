defmodule GateServer.Npc.Brain.Patrol do
  @moduledoc """
  全局系统功能：决策树后端。沿路点循环巡逻；配置了 `dig` 时，每到一个路点朝该方向探测，命中就攻击，
  冷却后重新探测，仍是同一个目标身份才继续，否则走向下一个路点。纯函数，无进程、无时钟（用 Observation 的 tick）。

  profile: `%{route: [{x, z}, ...], dig: %{direction: {dx, dy, dz}, tool_id: id} | nil}`
  """
  @behaviour GateServer.Npc.Brain

  @tolerance 0.5
  # 两次攻击之间的 tick 数；服务端按工具 interval 做速率裁决，这里只是不去撞它。
  @attack_gap 36

  @impl true
  def init(%{route: [_, _ | _] = route} = profile),
    do: %{route: route, dig: Map.get(profile, :dig), phase: :start, tick: 0, next_id: 1}

  @impl true
  def handle_event({:observation, %{self: %{tick: tick}}}, %{phase: :start} = state),
    do: walk(%{state | tick: tick})

  def handle_event({:observation, %{self: %{tick: tick}}}, %{phase: {:cooldown, until, target}} = state)
      when tick >= until,
      do: probe(%{state | tick: tick}, target)

  def handle_event({:observation, %{self: %{tick: tick}}}, state), do: {[], %{state | tick: tick}}

  def handle_event({:outcome, %{id: id, status: :done}}, %{phase: {:walking, id}, dig: nil} = state),
    do: walk(next(state))

  def handle_event({:outcome, %{id: id, status: :done}}, %{phase: {:walking, id}} = state),
    do: probe(state, nil)

  def handle_event(
        {:outcome, %{id: id, status: :done, data: target}},
        %{phase: {:probing, id, previous}} = state
      ) do
    if previous == nil or identity(previous) == identity(target),
      do: attack(state, target),
      else: walk(next(state))
  end

  def handle_event({:outcome, %{id: id, status: :done}}, %{phase: {:attacking, id, target}} = state),
    do: {[], %{state | phase: {:cooldown, state.tick + @attack_gap, target}}}

  # 探测或攻击被权威拒绝（射程外、目标已变…）：不重试，走向下一个路点。
  def handle_event({:outcome, %{id: id, status: :rejected}}, %{phase: {kind, id, _}} = state)
      when kind in [:probing, :attacking],
      do: walk(next(state))

  def handle_event({:outcome, _}, state), do: {[], state}

  defp identity(target), do: Map.take(target, [:micro, :incarnation, :owner, :material])
  defp next(%{route: [head | rest]} = state), do: %{state | route: rest ++ [head]}

  defp walk(%{route: [target | _]} = state),
    do: command(state, :walking, %{verb: :move_to, position: target, tolerance: @tolerance}, [])

  defp probe(state, previous),
    do: command(state, :probing, Map.put(state.dig, :verb, :probe_toward), [previous])

  defp attack(state, target),
    do: command(state, :attacking, Map.merge(state.dig, %{verb: :use_tool, target: target}), [target])

  defp command(%{next_id: id} = state, kind, command, extra) do
    phase = List.to_tuple([kind, id | extra])
    {[Map.put(command, :id, id)], %{state | phase: phase, next_id: id + 1}}
  end
end
