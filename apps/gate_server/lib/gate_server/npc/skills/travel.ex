defmodule GateServer.Npc.Skills.Travel do
  @moduledoc """
  全局系统功能：长途行走技能 `travel`（放置阶段决策稿 docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §7）。

  Body 的 `move_to` 单程水平不超过 `Perception.reach/0` 米（寻路取盒的上限）。`travel` 把到目标的直线等分成每段不超过
  reach − 2 米的若干段（`waypoints/3`），每段一个 Body `move_to`——仍由 Body 寻路、绕障、上台阶，与单程移动同一条裁决；
  任一段 `no_path` / `stuck` / `too_far` 即以该原因结束（不绕远、不重试，由调用方换目标）。done 返回
  `%{position:, legs:}`：最后一段 done 时的权威位置与走过的段数。

  调用方：扩张技能走向候选地块（`walk/2`）、Settler 回工地站位（树的 `travel` 叶子）、LLM 走远路（技能条目）。
  只经 Body 原子动作（`GateServer.Npc.Skill.call/2`），不读写 World。
  """
  @behaviour GateServer.Npc.Skill
  alias GateServer.Npc.{Actions, Perception, Skill}

  @metrics %{request_count: 0, jev_request_count: 0}
  # 每段的水平上限：比 move_to 单程上限留 2 米余量（路点落在格边、寻路盒外扩都不越界）。
  @leg Perception.reach() - 2

  @impl true
  def definition(_profile) do
    %{
      description:
        "走到水平坐标 (x, z)，可以很远：自动分成每段不超过 #{@leg} 米的直线段，每段照常寻路（绕障、上 1 格台阶、不跳、不进液体）。" <>
          "任一段走不通就结束并给出原因（no_path / stuck），换个目标再试。到了返回位置与段数。",
      parameters: %{
        type: "object",
        properties: %{x: %{type: "number"}, z: %{type: "number"}},
        required: ["x", "z"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def run(context, %{"x" => x, "z" => z}, _config) when is_number(x) and is_number(z) do
    state = %{
      body: context.body,
      call: context.call_id,
      step: 0,
      position: context.observation.self.position
    }

    case walk(state, {x, z}) do
      {:ok, state} -> {:ok, %{position: state.position, legs: state.step, metrics: @metrics}}
      {:error, reason, _state} -> {:error, reason, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}

  @doc """
  分段路点（纯函数）：从 `from` 到 `to`（水平 `{x, z}`）的直线等分成 n = ⌈距离 / leg⌉（至少 1）段，返回各段终点，最后一个恰是 `to`。
  """
  def waypoints({x0, z0}, {x1, z1} = to, leg) do
    n = max(1, ceil(:math.sqrt((x1 - x0) ** 2 + (z1 - z0) ** 2) / leg))
    for k <- 1..n, do: if(k == n, do: to, else: {x0 + (x1 - x0) * k / n, z0 + (z1 - z0) * k / n})
  end

  @doc """
  技能内部分段走到 `target`（水平 `{x, z}`）：每段一个 Body `move_to`（`Skill.call/2`），位置取 done data。`state` 是调用方技能的
  状态（`body`、`call`、`step`，以及当前 `position`）；返回 `{:ok, state}`（position 已更新）或 `{:error, 原因, state}`。
  """
  def walk(%{position: {px, _, pz}} = state, target) do
    {px, pz}
    |> waypoints(target, @leg)
    |> Enum.reduce_while({:ok, state}, fn point, {:ok, state} ->
      case Skill.call(state, %{verb: :move_to, position: point, tolerance: Actions.tolerance()}) do
        {:ok, %{position: position}, state} -> {:cont, {:ok, %{state | position: position}}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end
end
