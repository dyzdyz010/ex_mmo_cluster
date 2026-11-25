defmodule NpcServer.Skills.DigCell do
  @moduledoc """
  全局系统功能：从此刻站的位置挖掉一格天然宏格（NPC 原子 `dig_cell`，决策稿
  docs/10-active/cross-cutting/2026-11-24-npc-route-and-teleport-decision.md §5.4）。

  这是 `NpcServer.Skills.Gather.mine/3`（挖一格的完整流程：沿眼点 → 格心探测、命中恰是这一格的天然宏格才逐击 `use_tool`、
  两击至少隔工具间隔、`look` 确认成了空气）的技能壳，不复制流程；扩张平整地块、采石与它用的是同一个函数。
  不移动：眼点取技能开始时的观察位置（`Player.eye_position/1`）。路线查询（`NpcServer.Route`）列出的路线在每个
  `dig_cell` 前面都有一步 `move_to` 到规划的站位，“从这里挖得到”由路线保证，权威仍是最终裁决。

  结局：挖掉 → done `%{cell: [x, y, z]}`（材料按 World 的结算进余额）；`mine/3` 的两种“没挖成”原样作为原因——`blocked`
  （命中别的东西、射程外、`out_of_reach` / `occluded`）与 `foreign`（命中这一格但不是天然宏格，如作者 prefab 宏格）；
  其余拒绝原样来自权威（`protected_region`、`ineffective_tool`、`dead`、`session_lost` 等）。工具不在目录里 →
  `invalid_skill_arguments`，不动手。
  """
  @behaviour NpcServer.Skill
  alias NpcServer.Abilities
  alias NpcServer.Skills.Gather
  alias SceneServer.Movement.Player
  alias VoxelRegion.World

  @metrics %{request_count: 0, jev_request_count: 0}

  @impl true
  def definition(profile) do
    %{
      description:
        "从此刻站的位置挖掉一格天然宏格 (x, y, z)（1 格 = 1 米，整数格坐标），不移动：沿眼睛到格心探测，命中恰是这一格的天然宏格" <>
          "才用 tool_id 逐击挖，直到这一格成了空气；挖下的材料进自己的 balances。没挖成时以原因结束：blocked = 中间被别的东西挡住" <>
          "或在射程外；foreign = 这一格不是天然宏格（如预制件）；protected_region = 在别人的保护区；ineffective_tool = 这把工具敲不动它。",
      parameters: %{
        type: "object",
        properties: %{
          x: %{type: "integer"},
          y: %{type: "integer"},
          z: %{type: "integer"},
          tool_id: Abilities.belt_schema(profile)
        },
        required: ["x", "y", "z", "tool_id"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def run(context, %{"x" => x, "y" => y, "z" => z, "tool_id" => tool}, _config)
      when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(tool) do
    case World.tool_definition(context.world, tool) do
      {:ok, definition} ->
        state = %{
          body: context.body,
          call: context.call_id,
          step: 0,
          # 被别的技能组合时的步号命名空间（`Skill.call/2`）；单独调用时为 nil。
          space: Map.get(context, :step_space),
          tool: tool,
          interval_ms: round(definition["interval_seconds"] * 1_000),
          last_hit: nil
        }

        eye = Player.eye_position(context.observation.self.position)

        case Gather.mine({x, y, z}, eye, state) do
          {:mined, _state} -> {:ok, %{cell: [x, y, z], metrics: @metrics}}
          {missed, _state} when missed in [:blocked, :foreign] -> {:error, missed, @metrics}
          {:error, reason, _state} -> {:error, reason, @metrics}
        end

      :error ->
        {:error, :invalid_skill_arguments, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}
end
