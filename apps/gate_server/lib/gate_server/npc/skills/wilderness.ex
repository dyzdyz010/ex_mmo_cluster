defmodule GateServer.Npc.Skills.Wilderness do
  @moduledoc """
  全局系统功能：荒野逐格施工技能，直接运行 Builder 的原状态机。
  大脑只调用一次；内部 Body 命令以 `{:skill, call_id, id}` 标识，由大脑路由并还原 Outcome id。
  中断由外层技能运行器负责，此处只保留施工状态机自身的异常调度。

  context 必须提供 body、world、call_id、初始 observation 和 profile；可传 request 替换模型发送函数。
  profile 含 cid、tool_id、planner、scheduler、activities、memory。args 含 goal 和可选 ops。
  记忆只保存蓝图；同目标才复用。终态重新只读 World，不把旧观察或模型措辞当成完成依据。
  """
  require Logger
  alias GateServer.Npc.{Blueprint, Body}
  alias GateServer.Npc.Brain.{Builder, Llm}
  alias VoxelRegion.World

  @doc "同步运行，返回 {:ok, result} 或 {:error, blocked_result, metrics}。"
  def run(context, %{goal: goal} = args) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    profile = context.profile |> Map.put(:goal, goal)
      |> Map.put(:request, Map.get(context, :request, Map.get(context.profile, :request, &Llm.request/2)))
    context = %{context | profile: profile}
    ops = case args do
      %{ops: ops} -> ops
      _ ->
        case profile.memory.get(profile.cid, "plan", "current") do
          %{"goal" => ^goal, "ops" => ops} -> ops
          _ -> nil
        end
    end
    state = Builder.new(profile, ops)
    if Map.has_key?(args, :ops) and state.cells,
      do: effect({:remember, ops}, state, context)
    advance(state, {:observation, context.observation}, state.cells, context,
      %{request_count: 0, jev_request_count: 0})
  end

  defp advance(state, event, target, context, metrics) do
    {state, effects} = Builder.step(state, event)
    target = state.cells || target
    if state.phase == :idle do
      finish(state, target, effects, context, metrics)
    else
      metrics = Enum.reduce(effects, metrics, fn effect, metrics ->
        effect(effect, state, context)
        case effect do
          {:plan, _} -> Map.update!(metrics, :request_count, &(&1 + 1))
          {:triage, _} -> Map.update!(metrics, :jev_request_count, &(&1 + 1))
          _ -> metrics
        end
      end)
      receive do
        event -> advance(state, event, target, context, metrics)
      end
    end
  end

  defp effect({:command, command}, _, context),
    do: Body.command(context.body, %{command | id: {:skill, context.call_id, command.id}})
  defp effect({:plan, request}, _, %{profile: profile}) do
    Logger.info("npc_wilderness_plan cid=#{profile.cid} note=#{inspect(request.note)}")
    answer = with {:ok, response} <- profile.request.(profile.planner, Builder.plan_body(profile.planner, request)),
                  {:ok, ops} <- Builder.plan_ops(response) do
      {:blueprint, ops}
    else
      other -> {:plan_failed, other}
    end
    send(self(), answer)
  end
  defp effect({:triage, problem}, _, %{profile: profile}),
    do: send(self(), {:verdict, Builder.triage_verdict(profile, problem)})
  defp effect({:remember, ops}, state, %{profile: profile}),
    do: profile.memory.put(profile.cid, "plan", "current", %{"ops" => ops, "goal" => state.goal})
  defp effect(:forget, _, %{profile: profile}), do: profile.memory.delete(profile.cid, "plan", "current")
  defp effect({:journal, text}, state, %{profile: profile}) do
    Logger.info("npc_wilderness_journal cid=#{profile.cid} #{text}")
    profile.memory.journal(profile.cid, text, state.position || {0,0,0})
  end

  defp finish(state, target, effects, context, metrics) do
    remaining = if target do
      world = for %{cell: [x,y,z], material: material} <- World.material_snapshot(context.world,
        [context.profile.cid], Map.keys(target)).probe_occupancy, into: %{}, do: {{x,y,z}, material}
      Blueprint.remaining(target, world)
    else
      :unknown
    end
    completed = :forget in effects
    if completed and remaining == %{todo: [], wrong: []} do
      Enum.each(effects, &effect(&1, state, context))
      {:ok, %{status: :completed, cells: map_size(target), remaining: remaining, metrics: metrics}}
    else
      reason = if completed, do: :world_changed,
        else: Enum.find_value(effects, fn {:journal, text} -> text; _ -> nil end)
      if completed do
        effect({:journal, "Stopped wilderness: the World changed after the final look."}, state, context)
      else
        Enum.each(effects, &effect(&1, state, context))
      end
      {:error, %{status: :blocked, reason: reason, remaining: remaining}, metrics}
    end
  end
end
