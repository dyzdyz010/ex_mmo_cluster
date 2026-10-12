defmodule NpcServer.Skills.Travel do
  @moduledoc """
  全局系统功能：长途行走技能 `travel`（放置阶段决策稿 docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §7）。

  Body 的 `move_to` 单程水平不超过 `Perception.reach/0` 米（寻路取盒的上限）。`travel` 把到目标的直线等分成每段不超过
  reach − 2 米的若干段（`waypoints/3`），每段先 `survey` 段终点那一列，取离自己脚下最近的可站层（`stand_y/2`，列扫描规则同
  `Perception.floors/2`）作为该段的站立格 `y`，再交给 Body `move_to`——仍由 Body 寻路、绕障、上台阶，与单程移动同一条裁决。
  带 `y` 是因为 Body 的寻路取盒竖直只覆盖起点与给定 `y` 之间外扩 6 格：不给 `y` 时只看起点上下 6 格，高差更大的段一律
  `no_path`（2026-10-08 run06：住民从北坡去坡下的建房区，每段 no_path）。段终点列里没有站得下的层（水面、悬崖外、超出
  survey 的竖直范围）→ 以 `no_path` 结束；任一段 `no_path` / `stuck` / `too_far` 即以该原因结束（不绕远、不重试，由调用方换目标）。
  done 返回 `%{position:, legs:}`：最后一段 done 时的权威位置与走过的段数。

  调用方：扩张技能走向候选地块（`walk/2`）、Settler 回工地站位（树的 `travel` 叶子）、LLM 走远路（技能条目）。
  只经 Body 原子动作（`NpcServer.Skill.call/2`），不读写 World。
  """
  @behaviour NpcServer.Skill
  alias NpcServer.{Actions, Body, Perception, Skill}

  @metrics %{request_count: 0, jev_request_count: 0}
  # 每段的水平上限：比 move_to 单程上限留 2 米余量（路点落在格边、寻路盒外扩都不越界）。
  @leg Perception.reach() - 2

  @impl true
  def definition(_profile) do
    %{
      description:
        "走到水平坐标 (x, z)，可以很远：自动分成每段不超过 #{@leg} 米的直线段；每段先勘察段终点那一列，选离自己脚下最近、站得下的那一层，" <>
          "再照常寻路（绕障、上 1 格台阶、可以下落、不跳、不进液体），上下坡、跨台地都行。" <>
          "结束原因：no_path = 某段终点没有站得下的地面（水面、悬崖外）或现在没有路，stuck = 路上被堵住；换个目标或过一会儿再试。" <>
          "到了返回位置与段数。",
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
      position: context.observation.self.position,
      half_height: context.movement_profile.half_height
    }

    {px, _, pz} = state.position

    case walk(state, {x, z}) do
      {:ok, state} ->
        legs = length(waypoints({px, pz}, {x, z}, @leg))
        {:ok, %{position: state.position, legs: legs, metrics: @metrics}}

      {:error, reason, _state} ->
        {:error, reason, @metrics}
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
  段终点的站立格（纯函数）：`floors` 是段终点那一列站得下的地面层（`Perception.floors/2`，升序），`foot_y` 是自己脚所在格的 y。
  返回离脚下最近那一层的站立格 y（= 地面 + 1）；同样近时取低的那层（下落总能走到，上去要有台阶）。没有可站层 → nil。
  依据：只给水平目标时把它投到离当前位置最近的可行走面上，同 Recast/Detour `dtNavMeshQuery::findNearestPoly`（查询盒内取
  最近的可走多边形）。
  """
  def stand_y([], _foot_y), do: nil

  def stand_y(floors, foot_y),
    do: Enum.min_by(floors, &{abs(&1 + 1 - foot_y), &1}) + 1

  @doc """
  技能内部分段走到 `target`（水平 `{x, z}`）：每段先 `survey` 段终点列、按 `stand_y/2` 定站立格，再一个带 `y` 的 Body `move_to`
  （都经 `Skill.call/2`），位置取 done data。`state` 是调用方技能的状态（`body`、`call`、`step`、当前 `position` 与身体的
  `half_height`）；返回 `{:ok, state}`（position 已更新）或 `{:error, 原因, state}`（段终点没有可站层为 `:no_path`）。
  """
  def walk(%{position: {px, _, pz}} = state, target) do
    {px, pz}
    |> waypoints(target, @leg)
    |> Enum.reduce_while({:ok, state}, fn point, {:ok, state} ->
      with {:ok, y, state} <- level(state, point),
           {:ok, %{position: position}, state} <-
             Skill.call(state, %{
               verb: :move_to,
               position: point,
               tolerance: Actions.tolerance(),
               y: y
             }) do
        {:cont, {:ok, %{state | position: position}}}
      else
        {:error, _, _} = error -> {:halt, error}
      end
    end)
  end

  # 段终点那一列：survey 一列，按 stand_y/2 选层。
  defp level(state, {x, z}) do
    column = {floor(x), floor(z)}

    with {:ok, %{columns: [%{floors: floors}]}, state} <-
           Skill.call(state, %{verb: :survey, min: column, max: column}) do
      {_, foot_y, _} = Body.foot(state.position, state.half_height)

      case stand_y(floors, foot_y) do
        nil -> {:error, :no_path, state}
        y -> {:ok, y, state}
      end
    end
  end
end
